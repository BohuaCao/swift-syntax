//===------------ main.swift - Entry point for lit-test-help --------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//


import SwiftSyntax
import Foundation

/// Print the given message to stderr
func printerr(_ message: String, terminator: String = "\n") {
  FileHandle.standardError.write((message + terminator).data(using: .utf8)!)
}

/// Print the help message
func printHelp() {
  print("""
    Utility to test SwiftSyntax syntax tree creation.

    Actions (must specify one):
      -deserialize
            Deserialize a full pre-edit syntax tree (-pre-edit-tree) and write
            the source representation of the syntax tree to an out file (-out).
      -deserialize-incremental
            Deserialize a full pre-edit syntax tree (-pre-edit-tree), parse an
            incrementally transferred post-edit syntax tree (-incr-tree) and
            write the source representation of the post-edit syntax tree to an
            out file (-out).
      -classify-syntax
            Parse the given source file (-source-file) and output it with
            tokens classified for syntax colouring.
      -parse-incremental
            Parse a pre-edit source file (-old-source-file) and incrementally
            parse the post-edit source file (-source-file) that was the result
            of applying the given edits (-incremental-edit).
      -roundtrip
            Parse the given source file (-source-file) and print it out using
            its syntax tree.
      -print-tree
            Parse the given source file (-source-file) and output its syntax
            tree.
      -help
            Print this help message

    Arguments:
      -source-file FILENAME
            The path to a Swift source file to parse
      -old-source-file FILENAME
            Path to the pre-edit source file to translate line:column edits into
            the file's byte offsets.
      -incremental-edit EDIT
            An edit that was applied to reach the input file from the source
            file that generated the old syntax tree in the format <start-line>:
            <start-column>-<end-line>:<end-column>=<replacement> where start and
            end are dfined in terms of the pre-edit file and <replacement> is
            the string that shall replace the selected range. Can be passed
            multiple times.
      -reparse-region REGION
            If specified, an error will be emitted if any part of the file
            ouside of the reparse region gets parsed again. Can be passed
            multiple times to specify multiple reparse regions. Reparse regions
            are specified in the form <start-column>-<end-line>:<end-column> in
            terms of the post-edit file.
      -incremental-reuse-log FILENAME
            Path to which a log should be written that describes all the nodes
            reused during incremental parsing.
      -pre-edit-tree FILENAME
            The path to a JSON serialized pre-edit syntax tree
      -incr-tree FILENAME
            The path to a JSON serialized incrementally transferred post-edit
            syntax tree
      -serialization-format {json,byteTree} [default: json]
            The format that shall be used to serialize/deserialize the syntax
            tree. Defaults to json.
      -out FILENAME
            The file to which the source representation of the post-edit syntax
            tree shall be written.
    """)
}

extension CommandLineArguments {
  func getSerializationFormat() throws -> SerializationFormat {
    switch self["-serialization-format"] {
    case nil:
      return .json
    case "json":
      return .json
    case "byteTree":
      return .byteTree
    default:
      throw CommandLineArguments.InvalidArgumentValueError(
        argName: "-serialization-format",
        value: self["-serialization-format"]!
      )
    }
  }

  func getIncrementalEdits() throws -> [IncrementalEdit] {
    let regex = try NSRegularExpression(
      pattern: "([0-9]+):([0-9]+)-([0-9]+):([0-9]+)=(.*)")
    var parsedEdits = [IncrementalEdit]()
    let editArgs = try self.getRequiredValues("-incremental-edit")
    for edit in editArgs {
      guard let match =
          regex.firstMatch(in: edit,
                           range: NSRange(edit.startIndex..., in: edit)) else {
        throw CommandLineArguments.InvalidArgumentValueError(
          argName: "-incremental-edit",
          value: edit
        )
      }
      let region = getSourceRegion(match, text: edit)
      let replacement = match.match(at: 5, text: edit)
      parsedEdits.append(IncrementalEdit(
        region: region,
        replacement: replacement
      ))
    }
    return parsedEdits
  }

  func getReparseRegions() throws -> [SourceRegion] {
    let regex = try NSRegularExpression(
      pattern: "([0-9]+):([0-9]+)-([0-9]+):([0-9]+)")
    var reparseRegions = [SourceRegion]()
    let regionArgs = try self.getValues("-reparse-region")
    for regionStr in regionArgs {
      guard let match =
          regex.firstMatch(in: regionStr,
              range: NSRange(regionStr.startIndex..., in: regionStr)) else {
        throw CommandLineArguments.InvalidArgumentValueError(
          argName: "-reparse-region",
          value: regionStr
        )
      }
      let region = getSourceRegion(match, text: regionStr)
      reparseRegions.append(region)
    }
    return reparseRegions
  }

  private func getSourceRegion(_ match: NSTextCheckingResult,
                               text: String) -> SourceRegion {
    let matchAsInt = { (i: Int) -> Int in
      return Int(match.match(at: i, text: text))!
    }

    let startLine = matchAsInt(1)
    let startColumn = matchAsInt(2)
    let endLine = matchAsInt(3)
    let endColumn = matchAsInt(4)
    return SourceRegion(
      startLine: startLine,
      startColumn: startColumn,
      endLine: endLine,
      endColumn: endColumn
    )
  }
}

extension NSTextCheckingResult {
  func match(at: Int, text: String) -> String {
    let range = self.range(at: at)
    let text = String(text[Range(range, in: text)!])
    return text
  }
}

struct ByteSourceRangeSet {
  var ranges = [ByteSourceRange]()

  mutating func addRange(_ range: ByteSourceRange) {
    ranges.append(range)
  }

  func inverted(totalLength: Int) -> ByteSourceRangeSet {
    var result = ByteSourceRangeSet()
    var currentOffset = 0
    for range in ranges {
      assert(currentOffset <= range.offset,
             "Ranges must be sorted in ascending order and not be overlapping")
      if currentOffset < range.offset {
        result.addRange(ByteSourceRange(offset: currentOffset,
                                        length: range.offset-currentOffset))
      }
      currentOffset = range.endOffset
    }
    if currentOffset < totalLength {
      result.addRange(ByteSourceRange(offset: currentOffset,
                                      length: totalLength-currentOffset))
    }

    return result
  }

  func intersected(_ other: ByteSourceRangeSet) -> ByteSourceRangeSet {
    var intersection = ByteSourceRangeSet()
    for A in self.ranges {
      for B in other.ranges {
        let partialIntersection = A.intersected(B)
        if !partialIntersection.isEmpty {
          intersection.addRange(partialIntersection)
        }
      }
    }
    return intersection
  }
}

struct SourceRegion {
  let startLine: Int
  let startColumn: Int
  let endLine: Int
  let endColumn: Int
}

struct IncrementalEdit {
  let region: SourceRegion
  let replacement: String
}

func performDeserialize(args: CommandLineArguments) throws {
  let fileURL = URL(fileURLWithPath: try args.getRequired("-pre-edit-tree"))
  let outURL = URL(fileURLWithPath: try args.getRequired("-out"))
  let format = try args.getSerializationFormat()

  let fileData = try Data(contentsOf: fileURL)

  let deserializer = SyntaxTreeDeserializer()
  let tree = try deserializer.deserialize(fileData, serializationFormat: format)

  let sourceRepresenation = tree.description
  try sourceRepresenation.write(to: outURL, atomically: false, encoding: .utf8)
}

func performRoundTrip(args: CommandLineArguments) throws {
  let preEditTreeURL =
    URL(fileURLWithPath: try args.getRequired("-pre-edit-tree"))
  let incrTreeURL = URL(fileURLWithPath: try args.getRequired("-incr-tree"))
  let outURL = URL(fileURLWithPath: try args.getRequired("-out"))
  let format = try args.getSerializationFormat()

  let preEditTreeData = try Data(contentsOf: preEditTreeURL)
  let incrTreeData = try Data(contentsOf: incrTreeURL)

  let deserializer = SyntaxTreeDeserializer()
  _ = try deserializer.deserialize(preEditTreeData, serializationFormat: format)
  let tree = try deserializer.deserialize(incrTreeData,
                                          serializationFormat: format)
  let sourceRepresenation = tree.description
  try sourceRepresenation.write(to: outURL, atomically: false, encoding: .utf8)
}

func performClassifySyntax(args: CommandLineArguments) throws {
  let treeURL = URL(fileURLWithPath: try args.getRequired("-source-file"))

  let tree = try SyntaxParser.parse(treeURL)
  let classifications = SyntaxClassifier.classifyTokensInTree(tree)
  let printer = ClassifiedSyntaxTreePrinter(classifications: classifications)
  let result = printer.print(tree: tree)

  if let outURL = args["-out"].map(URL.init(fileURLWithPath:)) {
    try result.write(to: outURL, atomically: false, encoding: .utf8)
  } else {
    print(result)
  }
}

/// Returns an array of UTF8 bytes offsets for each line.
func getLineTable(_ text: String) -> [Int] {
  return text.withCString { (p: UnsafePointer<Int8>) -> [Int] in
    var lineOffsets = [Int]()
    lineOffsets.append(0)
    var idx = 0
    while p[idx] != 0 {
      if p[idx] == Int8(UnicodeScalar("\n").value) {
        lineOffsets.append(idx+1)
      }
      idx += 1
    }
    return lineOffsets
  }
}

func getByteRange(_ region: SourceRegion, lineTable: [Int],
                  argName: String) throws -> ByteSourceRange {
  if region.startLine-1 >= lineTable.count {
      throw CommandLineArguments.InvalidArgumentValueError(
        argName: argName,
        value: "startLine: \(region.startLine)"
      )
  }
  if region.endLine-1 >= lineTable.count {
      throw CommandLineArguments.InvalidArgumentValueError(
        argName: argName,
        value: "endLine: \(region.endLine)"
      )
  }
  let startOffset = lineTable[region.startLine-1] + region.startColumn-1
  let endOffset = lineTable[region.endLine-1] + region.endColumn-1
  let length = endOffset-startOffset
  return ByteSourceRange(offset: startOffset, length: length)
}

func parseIncrementalEditArguments(
  args: CommandLineArguments
) throws -> [SourceEdit] {
  var edits = [SourceEdit]()
  let argEdits = try args.getIncrementalEdits()
  let preEditURL =
    URL(fileURLWithPath: try args.getRequired("-old-source-file"))
  let text = try String(contentsOf: preEditURL)
  let lineTable = getLineTable(text)
  for argEdit in argEdits {
    let range = try getByteRange(argEdit.region, lineTable: lineTable,
                                 argName: "-incremental-edit")
    let replacementLength = argEdit.replacement.utf8.count
    edits.append(SourceEdit(range: range, replacementLength: replacementLength))
  }
  return edits
}

func performParseIncremental(args: CommandLineArguments) throws {
  let preEditURL =
    URL(fileURLWithPath: try args.getRequired("-old-source-file"))
  let postEditURL = URL(fileURLWithPath: try args.getRequired("-source-file"))
  let expectedReparseRegions = try args.getReparseRegions()

  let preEditTree = try SyntaxParser.parse(preEditURL)
  let edits = try parseIncrementalEditArguments(args: args)
  let regionCollector = IncrementalParseReusedNodeCollector()
  let editTransition = IncrementalEditTransition(previousTree: preEditTree,
    edits: edits, reusedNodeDelegate: regionCollector)

  let postEditText = try String(contentsOf: postEditURL)
  let postEditTree =
    try SyntaxParser.parse(source: postEditText, parseLookup: editTransition)

  let postTreeDump = postEditTree.description

  if let outURL = args["-out"].map(URL.init(fileURLWithPath:)) {
    try postTreeDump.write(to: outURL, atomically: false, encoding: .utf8)
  } else {
    print(postTreeDump)
  }

  let regions = regionCollector.rangeAndNodes.map { $0.0 }
  if let reuseLogURL =
    args["-incremental-reuse-log"].map(URL.init(fileURLWithPath:)) {
    var log = ""
    for region in regions {
      log += "Reused \(region.offset) to \(region.endOffset)\n"
    }
    try log.write(to: reuseLogURL, atomically: false, encoding: .utf8)
  }

  if !expectedReparseRegions.isEmpty {
    try verifyReusedRegions(expectedReparseRegions: expectedReparseRegions,
      reusedRegions: regions,
      sourceURL: preEditURL)
  }
}

enum TestingError: Error, CustomStringConvertible {
  case reparsedRegionsVerificationFailed(ByteSourceRange)

  public var description: String {
    switch self {
    case .reparsedRegionsVerificationFailed(let range):
      return "unexpectedly reparsed following region: (offset: \(range.offset),"
        + " length:\(range.length))"
    }
  }
}

func verifyReusedRegions(expectedReparseRegions: [SourceRegion],
      reusedRegions: [ByteSourceRange],
      sourceURL: URL) throws {
  let text = try String(contentsOf: sourceURL)
  let fileLength = text.utf8.count

  // Compute the repared regions by inverting the reused regions
  let reusedRanges = ByteSourceRangeSet(ranges: reusedRegions)
  let reparsedRegions = reusedRanges.inverted(totalLength: fileLength)

  // Same for expected reuse regions
  let lineTable = getLineTable(text)
  var expectedReparseRanges = ByteSourceRangeSet()
  for region in expectedReparseRegions {
    let range =
      try getByteRange(region, lineTable: lineTable, argName: "-reparse-region")
    expectedReparseRanges.addRange(range)
  }
  let expectedReuseRegions =
    expectedReparseRanges.inverted(totalLength: fileLength)

  // Intersect the reparsed regions with the expected reuse regions to get
  // regions that should not have been reparsed
  let unexpectedReparseRegions =
      reparsedRegions.intersected(expectedReuseRegions)

  for reparseRange in unexpectedReparseRegions.ranges {
    // To improve the ergonomics when writing tests we do not want to complain
    // about reparsed whitespaces.
    let utf8 = text.utf8
    let begin = utf8.index(utf8.startIndex, offsetBy: reparseRange.offset)
    let end = utf8.index(begin, offsetBy: reparseRange.length)
    let rangeStr = String(utf8[begin..<end])!
    let whitespaceOnlyRegex = try NSRegularExpression(pattern: "^[ \t\r\n]*$")
    let match = whitespaceOnlyRegex.firstMatch(in: rangeStr,
                          range: NSRange(rangeStr.startIndex..., in: rangeStr))
    if match != nil {
      continue
    }
    throw TestingError.reparsedRegionsVerificationFailed(reparseRange)
  }
}

func performRoundtrip(args: CommandLineArguments) throws {
  let sourceURL = URL(fileURLWithPath: try args.getRequired("-source-file"))
  let tree = try SyntaxParser.parse(sourceURL)
  let treeText = tree.description

  if let outURL = args["-out"].map(URL.init(fileURLWithPath:)) {
    try treeText.write(to: outURL, atomically: false, encoding: .utf8)
  } else {
    print(treeText)
  }
}

class NodePrinter: SyntaxVisitor {
  override func visitPre(_ node: Syntax) {
    assert(!node.isUnknown)
    print("<\(type(of: node))>", terminator: "")
  }
  override func visitPost(_ node: Syntax) {
    print("</\(type(of: node))>", terminator: "")
  }
  override func visit(_ token: TokenSyntax) -> SyntaxVisitorContinueKind {
    print(token, terminator:"")
    return .visitChildren
  }
}

func printSyntaxTree(args: CommandLineArguments) throws {
  let treeURL = URL(fileURLWithPath: try args.getRequired("-source-file"))
  let tree = try SyntaxParser.parse(treeURL)
  tree.walk(NodePrinter())
}

do {
  let args = try CommandLineArguments.parse(CommandLine.arguments.dropFirst())

  if args.has("-deserialize-incremental") {
    try performRoundTrip(args: args)
  } else if args.has("-classify-syntax") {
    try performClassifySyntax(args: args)
  } else if args.has("-parse-incremental") {
    try performParseIncremental(args: args)
  } else if args.has("-roundtrip") {
    try performRoundtrip(args: args)
  } else if args.has("-deserialize") {
    try performDeserialize(args: args)
  } else if args.has("-print-tree") {
    try printSyntaxTree(args: args)
  } else if args.has("-help") {
    printHelp()
  } else {
    printerr("""
      No action specified.
      See -help for information about available actions
      """)
    exit(1)
  }
  exit(0)
} catch {
  printerr("\(error)")
  printerr("Run swift-swiftsyntax-test -help for more help.")
  exit(1)
}
