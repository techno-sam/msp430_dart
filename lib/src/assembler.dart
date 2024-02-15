/*
 *     MSP430 emulator and assembler
 *     Copyright (C) 2023-2024  Sam Wagenaar
 *
 *     This program is free software: you can redistribute it and/or modify
 *     it under the terms of the GNU General Public License as published by
 *     the Free Software Foundation, either version 3 of the License, or
 *     (at your option) any later version.
 *
 *     This program is distributed in the hope that it will be useful,
 *     but WITHOUT ANY WARRANTY; without even the implied warranty of
 *     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *     GNU General Public License for more details.
 *
 *     You should have received a copy of the GNU General Public License
 *     along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'dart:io';
import 'dart:typed_data';
import 'package:collection/collection.dart' show DelegatingList;

import '../msp430_dart.dart';

/*
Assembly steps:
src --> lines --> read symbols --> apply symbols --> Tokenizer -->
    Section builder (as classes, labels linked, starts with unknown addresses after an error but keeps going) -->
    (up to first error) compiled (by line) --> (if no errors) output file
*/

/*
needed tokens:

lineStart       - start of a line
label           - what it says on the tin
mnemonic        - instruction (mnemonic)
modeInd         - byte/word indicator (false = word, true = byte)
value           - numeric value for an argument
labelVal        - label value for an argument

>>>>>>>>>>>>> arguments (require a 'value' after)
argRegd         - register direct
argIdx          - indexed (requires two 'value's (index and register)
argRegi         - register indirect
argRegia        - register indirect autoincrement
argSym          - symbolic
argImm          - immediate
argAbs          - absolute
>>>>>>>>> constant arg is parsed later from immediate

 */

class CallbackOnAddList<E> extends DelegatingList<E> {
  void Function(E) onAdd;

  CallbackOnAddList(super.base, this.onAdd);

  @override
  void add(value) {
    onAdd(value);
    super.add(value);
  }
}

extension WrapWithAddCallback<E> on List<E> {
  CallbackOnAddList<E> onAdd(void Function(E) onAdd) {
    return CallbackOnAddList(this, onAdd);
  }
}

NestedTracker _panicOnRecursionLimit = NestedTracker();

class MacroRecursionError extends Error {
  final Line line;

  MacroRecursionError(this.line);

  @override
  String toString() {
    return "Macro recursion limit reached on line: ${line.num}:\t${line.contents}";
  }
}

class LineId extends Pair<int, String> {
  final int? includedByLine;
  const LineId(super.first, super.second): includedByLine = null;
  const LineId.included(super.first, super.second, this.includedByLine);

  LineId copyWith({
    int? lineNo,
    String? source,
    int? includedByLine
  }) {
    lineNo ??= first;
    source ??= second;
    includedByLine ??= this.includedByLine;
    if (includedByLine != null) {
      return LineId.included(lineNo, source, includedByLine);
    } else {
      return LineId(lineNo, source);
    }
  }

  @override
  String toString() {
    return second.isEmpty ? "$first" : "$first ($second)";
  }
}


class Line {
  final LineId num;
  final String contents;
  Line(this.num, this.contents);

  Line set(String contents) => Line(num, contents);

  Pair<Line, String> error(String error) => Pair(this, error);
}


enum Tokens<T> {
  lineStart<LineId>(LineId(0, "")),
  label<String>(""),
  mnemonic<String>(""),
  modeInd<bool>(false),
  value<int>(0),
  labelVal<String>(""),
  argRegd<void>(null),
  argIdx<void>(null),
  argRegi<void>(null),
  argRegia<void>(null),
  argSym<void>(null),
  argImm<void>(null),
  argAbs<void>(null),
  dataMode<void>(null),
  cString8Data<String>(""),
  interrupt<int>(0), // expects a labelVal to follow it
  dbgBreak<void>(null),
  listingComment<String>(""),
  ;
  final T _sham;
  const Tokens(this._sham);

  Token<T> call([T? value]) {
    if ((value == null) != (T == Null || _sham == null)) {
      throw AssertionError("$this requires an argument of type $T");
    }
    return Token<T>(this, value);
  }

  static Token<String> makeLabel(String value, String prefix) {
    if (value.startsWith("\$")) {
      value = prefix + value;
    }
    return Token<String>(label, value);
  }

  static Token<String> makeLabelVal(String value, String prefix) {
    if (value.startsWith("\$")) {
      value = prefix + value;
    }
    return Token<String>(labelVal, value);
  }

  bool get isArg => name.startsWith("arg");

  bool get isVal => this == value;
  bool get isLblVal => this == labelVal;
}

class Token<T> {
  final Tokens<T> token;
  final T? value;
  const Token(this.token, this.value);

  @override
  String toString() {
    String color = "";
    if (token == Tokens.lineStart) {
      color = Fore.LIGHTGREEN_EX;
    } else if (token == Tokens.mnemonic) {
      color = Fore.LIGHTBLUE_EX;
    } else if (token == Tokens.label) {
      color = Fore.YELLOW;
    } else if (token == Tokens.value || token == Tokens.labelVal) {
      color = Fore.MAGENTA;
    } else if ([Tokens.argRegd, Tokens.argIdx, Tokens.argRegi, Tokens.argRegia, Tokens.argSym, Tokens.argImm, Tokens.argAbs].contains(token)) {
      color = Fore.LIGHTRED_EX;
    } else if (token == Tokens.dataMode) {
      color = Fore.BLUE;
    } else if (token == Tokens.cString8Data) {
      color = Fore.LIGHTCYAN_EX;
    } else if (token == Tokens.interrupt) {
      color = Fore.LIGHTCYAN_EX;
    }
    return '$color${token.name}<$T>[$value]${Style.RESET_ALL}';
  }

  bool get isArg => token.isArg;

  bool get isVal => token.isVal;

  bool get isLblVal => token.isLblVal;
}

String filePathToDirectory(String filePath) {
  List<String> split = filePath.split(Platform.pathSeparator);
  split.removeLast();
  return split.join(Platform.pathSeparator);
}

List<Line> parseLines(String txt, {String fileName = "", List<String>? blockedIncludes, int? includedByLine, Directory? containingDirectory}) {
  containingDirectory ??= Directory.current;
  List<String> strings = txt.split("\n");
  List<Line> lines = [];
  for (int i = 0; i < strings.length; i++) {
    String line = strings[i].trim();
    RegExpMatch? match = re.include.firstMatch(line);
    String? includePath;
    if (match != null && (includePath = match.namedGroup("path")) != null) {
      File file = File(containingDirectory.absolute.uri.resolve(includePath!).path);
      Directory subContainingDirectory = Directory.fromUri(containingDirectory.uri.resolve(filePathToDirectory(includePath)));
      if (file.existsSync()) {
        lines.add(Line(LineId.included(i, fileName, includedByLine), ".push_locblk"));
        lines.add(Line(LineId.included(i, fileName, includedByLine), ".dbgbrk"));
        String fileContents = file.readAsStringSync();
        blockedIncludes ??= [];
        if (blockedIncludes.contains(includePath)) {
          // ignore (don't recursively include files)
        } else {
          blockedIncludes.add(includePath);
          lines.addAll(parseLines(fileContents, fileName: includePath, blockedIncludes: blockedIncludes, includedByLine: includedByLine ?? i, containingDirectory: subContainingDirectory));
        }
        lines.add(Line(LineId.included(i, fileName, includedByLine), ".dbgbrk"));
        lines.add(Line(LineId.included(i, fileName, includedByLine), ".pop_locblk"));
      } else {
        lines.add(Line(LineId.included(i, fileName, includedByLine), "!!!File '$includePath' not found"));
      }
    } else {
      lines.add(Line(LineId.included(i, fileName, includedByLine), line));
    }
  }
  return lines;
}

List<Line> parseIncludeErrors(List<Line> lines, List<Pair<Line, String>> erroringLines) {
  lines.where((line) => line.contents.startsWith("!!!"))
      .forEach((line) => erroringLines.add(Pair(line, line.contents.replaceFirst("!!!", ""))));
  return lines.where((line) => !line.contents.startsWith("!!!")).toList();
}

List<Line> parseDefines(List<Line> lines, List<Pair<Line, String>> erroringLines) {
  Iterable<Line> defineLines = lines.where((line) => line.contents.startsWith(".define"));
  Iterable<Line> remainingLines = lines.where((line) => !line.contents.startsWith(".define"));
  Map<String, String> defines = {};
  // load defines
  for (Line line in defineLines) {
    RegExpMatch? match = re.define.firstMatch(line.contents);
    if (match == null) {
      erroringLines.add(Pair(line, "parsing define failed"));
    } else {
      defines[match.group(2)!] = match.group(1)!;
    }
  }
  // apply defines
  List<Line> out = [];
  for (Line line in remainingLines) {
    String contents = line.contents;
    for (MapEntry<String, String> entry in defines.entries) {
      contents = contents.replaceAll("[${entry.key}]", entry.value);
    }
    out.add(line.set(contents));
  }
  return out;
}

class Macro {
  final String name;
  final List<String> parameters;
  /// NOTE: not final lines, but rather lines *within* the macro
  final List<Line> _lines;

  Iterable<Line> realizedLines(List<String> arguments) {
    return _lines.map((line) {
      String newContents = line.contents;
      for (int i = 0; i < parameterCount; i++) {
        final from = parameters[i];
        final to = arguments[i];
        newContents = newContents.replaceAll("{$from}", to);
      }
      return line.set(newContents);
    });
  }

  int get parameterCount => parameters.length;
  String get qualifier => "$name|$parameterCount|";

  Macro({required this.name, required this.parameters, required List<Line> lines}): _lines = lines;
}

class MacroBuilder {
  String? _name;
  List<String>? _parameters;
  int _lineNo = 0;
  final List<Line> _lines = [];

  set name(String name) => _name = name;
  set parameters(List<String> parameters) => _parameters = parameters;

  void addLine(Line line) {
    //print("Adding line to macro $_name: ${line.contents}");
    _lines.add(Line(line.num.copyWith(source: "${line.num.second.isEmpty ? "" : "${line.num.second}: "}<PLACEHOLDER>:${++_lineNo}"), line.contents));
  }

  List<Line> _processLines() {
    return _lines.map((line) => Line(
        line.num.copyWith(source: line.num.second.replaceFirst("<PLACEHOLDER>", _name!)),
        line.contents
    )).toList(growable: false);
  }

  Macro? build() {
    if (_name == null || _parameters == null) {
      return null;
    }
    return Macro(
      name: _name!,
      parameters: _parameters!,
      lines: _processLines()
    );
  }
}

/*
; definition
.macro test_macro(a, beta, t3st)
mov {a} r6
add {beta} 0({t3st})
mov @{t3st} {a}
.endmacro

; invocation
test_macro(r5, #0x4201, r7)
 */
List<Line> parseMacros(List<Line> lines, List<Pair<Line, String>> erroringLines) {
  final Map<String, Macro> macros = {};

  List<Line> remainingLines = [];
  // load macros
  final NestedTracker tracker = NestedTracker();
  MacroBuilder? builder;
  Line? outerMacroStart;
  for (Line line in lines) {
    // .macro
    RegExpMatch? match = re.macro.firstMatch(line.contents.trimComments());
    if (match != null) {
      if (tracker.enter()) {
        erroringLines.add(Pair(line, "nested macros are not supported"));
      } else {
        builder = MacroBuilder();
        builder.name = match.namedGroup("name")!;
        String? params = match.namedGroup("args");
        builder.parameters = params?.split(re.argsSep) ?? const [];
        outerMacroStart = line;
      }
      continue;
    }

    // .endmacro
    if (re.endMacro.hasMatch(line.contents.trimComments())) {
      bool shouldBuild = false;
      try {
        shouldBuild = !tracker.exit();
      } on NestingEscapeError {
        erroringLines.add(Pair(line, "unbalanced .endmacro"));
        continue;
      }
      if (shouldBuild) {
        Macro? macro = builder?.build();
        if (macro != null) {
          macros[macro.qualifier] = macro;
        }
        builder = null;
      }
      continue;
    }

    // potential contents
    if (tracker.depth == 1) {
      builder?.addLine(line);
    } else if (tracker.depth == 0) {
      remainingLines.add(line);
    }
  }
  if (tracker.depth > 0 || builder != null) {
    erroringLines.add(Pair(outerMacroStart!, "unclosed macro"));
  }

  // apply macros
  bool didExpand = true;
  List<Line> out = remainingLines;
  int escape = 128;
  while (didExpand) { // multiple passes to let nesting work
    escape--;
    didExpand = false;
    remainingLines = out;
    out = [];

    for (Line line in remainingLines) {
      final trimmedLine = line.contents.trimComments();
      final RegExpMatch? match = re.macroInvocation.firstMatch(trimmedLine);
      if (match != null) {
        didExpand = true;
        if (escape <= 0) {
          erroringLines.add(Pair(line, "macro expansion recursion limit reached"));
          out.add(line.set("nop"));
          didExpand = false;
          continue;
        }
        final String name = match.namedGroup("name")!;
        final String? argStr = match.namedGroup("args");
        final List<String> args = argStr?.split(re.argsSep) ?? [];
        final String qualifier = "$name|${args.length}|";
        if (macros.containsKey(qualifier)) {
          final Macro macro = macros[qualifier]!;
          out.add(Line(line.num.copyWith(), ".push_locblk"));
          out.add(Line(line.num.copyWith(), ".dbgbrk"));
          out.add(Line(line.num.copyWith(), ";!! Macro invocation: $trimmedLine"));
          for (Line mLine in macro.realizedLines(args)) {
            out.add(Line(mLine.num.copyWith(includedByLine: line.num.first),
                mLine.contents));
          }
          out.add(Line(line.num.copyWith(), ".pop_locblk"));
          out.add(Line(line.num.copyWith(), ".dbgbrk"));
        } else {
          line = line.set("nop");
          out.add(line);
          erroringLines.add(Pair(
              line, "macro '$name' not found for ${args.length} parameters"));
        }
      } else {
        out.add(line);
      }
    }
  }
  return out;
}

/*
(copied from above)

labelVal        - label value for an argument
>>>>>>>>> arguments (require a 'value' after)
argRegd         - register direct
argIdx          - indexed (requires two 'value's (index and register)
argRegi         - register indirect
argRegia        - register indirect autoincrement
argSym          - symbolic
argImm          - immediate
argAbs          - absolute
 */
List<Token>? parseArgument(String txt) {
  txt = txt.trim();
  if (txt.isEmpty) return null;
  var tl = txt.toLowerCase();
  var namedRegisters = {
    "pc": "r0",
    "sp": "r1",
    "sr": "r2",
    "cg": "r3"
  };
  if (namedRegisters.containsKey(tl)) {
    tl = txt = namedRegisters[tl]!;
  }
  if (tl.startsWith("r")) { // register direct
    int? regNum = int.tryParse(tl.substring(1));
    if (regNum == null) return null;
    return [Tokens.argRegd(), Tokens.value(regNum)];
  } else if (re.regIdx.hasMatch(tl)) { // indexed
    var match = re.regIdx.firstMatch(tl)!;
    String sign = match.namedGroup("sign") ?? "+";
    String? digits = match.namedGroup("digits")?.toLowerCase();
    String? hex = match.namedGroup("hex")?.toLowerCase();
    String? reg = match.namedGroup("reg")?.toLowerCase();
    if (digits == null && hex == null) return null;
    if (reg == null) return null;
    int? idx;
    if (hex != null) {
      idx = int.tryParse(hex, radix: 16);
    } else {
      idx = int.tryParse(digits!);
    }
    if (idx == null) return null;
    if (sign == "-") {
      idx *= -1;
    } else if (sign != "+") {
      return null;
    }
    reg = namedRegisters[reg] ?? reg;
    int? regNum = int.tryParse(reg.substring(1));
    if (regNum == null) return null;
    return [Tokens.argIdx(), Tokens.value(idx), Tokens.value(regNum)];
  } else if (re.regIndirect.hasMatch(tl)) { // register indirect (autoincrement)
    var match = re.regIndirect.firstMatch(tl)!;
    var reg = match.namedGroup("reg");
    var autoincrement = match.namedGroup("autoincrement") == "+";
    reg = namedRegisters[reg] ?? reg;
    if (reg == null) return null;
    int? regNum = int.tryParse(reg.substring(1));
    if (regNum == null) return null;
    return [autoincrement ? Tokens.argRegia() : Tokens.argRegi(), Tokens.value(regNum)];
  } else if (re.regImmediate.hasMatch(tl)) { // register immediate
    var match = re.regImmediate.firstMatch(tl)!;
    String sign = match.namedGroup("sign") ?? "+";
    String? digits = match.namedGroup("digits")?.toLowerCase();
    String? hex = match.namedGroup("hex")?.toLowerCase();
    if (digits == null && hex == null) return null;
    int? val;
    if (hex != null) {
      val = int.tryParse(hex, radix: 16);
    } else {
      val = int.tryParse(digits!);
    }
    if (val == null) return null;
    if (sign == "-") {
      val *= -1;
    } else if (sign != "+") {
      return null;
    }
    return [Tokens.argImm(), Tokens.value(val)];
  } else if (re.regAbsolute.hasMatch(tl)) { //register absolute
    var match = re.regAbsolute.firstMatch(tl)!;
    String? digits = match.namedGroup("digits")?.toLowerCase();
    String? hex = match.namedGroup("hex")?.toLowerCase();
    if (digits == null && hex == null) return null;
    int? val;
    if (hex != null) {
      val = int.tryParse(hex, radix: 16);
    } else {
      val = int.tryParse(digits!);
    }
    if (val == null) return null;
    return [Tokens.argAbs(), Tokens.value(val)];
  } else if (re.unsignedNumber.hasMatch(tl)) { // symbolic
    var match = re.unsignedNumber.firstMatch(tl)!;
    String? digits = match.namedGroup("digits")?.toLowerCase();
    String? hex = match.namedGroup("hex")?.toLowerCase();
    if (digits == null && hex == null) return null;
    int? val;
    if (hex != null) {
      val = int.tryParse(hex, radix: 16);
    } else {
      val = int.tryParse(digits!);
    }
    if (val == null) return null;
    return [Tokens.argSym(), Tokens.value(val)];
  } else { // probably a label
    /*
    addressing modes where label is relevant:
    indexed     x(Rn)
    symbolic    ADDR
    absolute    &ADDR
    immediate   #x
     */
    if (re.regIdxLbl.hasMatch(txt)) { // indexed
      var match = re.regIdxLbl.firstMatch(txt)!;
      String? lbl = match.namedGroup("label");
      String? reg = match.namedGroup("reg")?.toLowerCase();
      reg = namedRegisters[reg] ?? reg;
      if (lbl == null || reg == null) return null;
      reg = namedRegisters[reg] ?? reg;
      int? regNum = int.tryParse(reg.substring(1));
      if (regNum == null) return null;
      return [Tokens.argIdx(), Tokens.labelVal(lbl), Tokens.value(regNum)];
    } else if (re.regAbsoluteLbl.hasMatch(txt)) { // absolute
      var match = re.regAbsoluteLbl.firstMatch(txt)!;
      String? lbl = match.namedGroup("label");
      if (lbl == null) return null;
      return [Tokens.argAbs(), Tokens.labelVal(lbl)];
    } else if (re.regImmediateLbl.hasMatch(txt)) { // immediate
      var match = re.regImmediateLbl.firstMatch(txt)!;
      String? lbl = match.namedGroup("label");
      if (lbl == null) return null;
      return [Tokens.argImm(), Tokens.labelVal(lbl)];
    } else if (re.label.hasMatch(txt)) { // symbolic
      var match = re.label.firstMatch(txt)!;
      String? lbl = match.group(1);
      if (lbl == null) return null;
      return [Tokens.argSym(), Tokens.labelVal(lbl)];
    } else {
      return null;
    }
  }
}

List<Token> _deduplicateLineStarts(List<Token> tokens) {
  List<Token> out = [];
  for (int i = 0; i < tokens.length; i++) {
    Token token = tokens[i];
    if (token.token == Tokens.lineStart) {
      if (i == 0 || tokens[i - 1].token != Tokens.lineStart || tokens[i - 1].value != token.value) {
        out.add(token);
      }
    } else {
      out.add(token);
    }
  }
  return out;
}

List<Token> parseTokens(List<Line> lines, List<Pair<Line, String>> erroringLines) {
  List<Token> tokens = [];
  List<Token> dataTokens = [Tokens.dbgBreak(), Tokens.dataMode()];
  _LocalPrefixGenerator prefixGen = _LocalPrefixGenerator();
  Stack<String> localLabelPrefix = Stack([prefixGen.next()]);
  bool dataMode = false;
  for (Line line in lines) {
    List<Token> tentativeTokens = [];
    tentativeTokens.add(Tokens.lineStart(line.num));
    dataTokens.add(Tokens.lineStart(line.num));
    String val = line.contents.trim();

    {
      RegExpMatch? match = re.listingComment.firstMatch(val.trim());
      if (match != null) {
        tentativeTokens.add(Tokens.listingComment(match.namedGroup("msg")!));
        tokens.addAll(tentativeTokens);
        continue;
      }
    }

    if (val.contains(";")) {
      val = val.split(";")[0].trimRight();
    }
    if (val == "") {
      tokens.addAll(tentativeTokens);
      continue;
    }

    // check for debugging helpers
    if (re.dbgBreak.firstMatch(val) != null) {
      tentativeTokens.add(Tokens.dbgBreak());
      tokens.addAll(tentativeTokens);
      continue;
    }

    // check for data mode
    if (re.dataMode.firstMatch(val) != null) {
      if (dataMode) {
        erroringLines.add(line.error("Already in data mode"));
        continue;
      }
      dataMode = true;
      tokens.addAll(tentativeTokens);
      continue;
    }

    if (re.textMode.firstMatch(val) != null) {
      if (!dataMode) {
        erroringLines.add(line.error("Already in text mode"));
        continue;
      }
      dataMode = false;
      tokens.addAll(tentativeTokens);
      continue;
    }

    if (val.contains(":")) { // check for a label
      List<String> parts = val.split(":");
      if (parts.length > 2) {
        erroringLines.add(line.error("Failed to parse label"));
        continue;
      }
      String label = parts[0].trim();
      val = parts[1].trim();
      var match = re.label.firstMatch(label);
      if (match?.groupCount != 1) {
        erroringLines.add(line.error("Failed to parse label (invalid characters?)"));
        continue;
      }
      label = match!.group(1)!;
      tentativeTokens.add(Tokens.makeLabel(label, localLabelPrefix.peek()));
      if (val == '') {
        (dataMode ? dataTokens : tokens).addAll(tentativeTokens);
        continue;
      }
    }

    if (dataMode) {
      RegExpMatch? cString8Match = re.cString8.firstMatch(val);
      if (cString8Match != null) {
        dataTokens.addAll(tentativeTokens);
        dataTokens.add(Tokens.cString8Data(cString8Match.namedGroup("string")!));
        continue;
      }
      erroringLines.add(line.error("Non-data value found in data block"));
      continue;
    }

    { // interrupt
      RegExpMatch? interruptMatch = re.interrupt.firstMatch(val);
      if (interruptMatch != null) {
        String? vectorDigits = interruptMatch.namedGroup("vector_digits");
        String? vectorHex = interruptMatch.namedGroup("vector_hex");
        String? targetLabel = interruptMatch.namedGroup("target_label");
        if (vectorDigits == null && vectorHex == null) {
          erroringLines.add(line.error("Failed to parse interrupt vector"));
          continue;
        }
        int? vector;
        if (vectorHex != null) {
          vector = int.tryParse(vectorHex, radix: 16);
        } else {
          vector = int.tryParse(vectorDigits!);
        }
        if (vector == null) {
          erroringLines.add(line.error("Failed to parse interrupt vector"));
          continue;
        }
        if (targetLabel == null) {
          erroringLines.add(line.error("Failed to parse interrupt target label"));
          continue;
        }
        tentativeTokens.add(Tokens.interrupt(vector));
        tentativeTokens.add(Tokens.makeLabelVal(targetLabel, localLabelPrefix.peek()));
        tokens.addAll(tentativeTokens);
        continue;
      }
    }

    { // local block
      if (re.localBlock.firstMatch(val) != null) {
        localLabelPrefix.clear();
        localLabelPrefix.push(prefixGen.next());
        continue;
      }

      if (re.localBlockPush.firstMatch(val) != null) {
        localLabelPrefix.push(prefixGen.next());
        continue;
      }

      if (re.localBlockPop.firstMatch(val) != null) {
        localLabelPrefix.pop();
        if (localLabelPrefix.isEmpty) {
          localLabelPrefix.push(prefixGen.next());
        }
        continue;
      }
    }

    List<String> matches = re.whitespaceSplit.allMatches(val)
        .map((e) => (e.group(1) ?? '').trim())
        .where((e) => e != '')
        .toList();
    if (matches.length > 3 || matches.isEmpty) {
      erroringLines.add(line.error("Wrong number of arguments"));
      continue;
    }
    var mnemonic = matches[0].toLowerCase();
    var bw = "";
    if (mnemonic.contains(".")) {
      var parts = mnemonic.split(".").toList();
      if (parts.length > 2) {
        erroringLines.add(line.error("Invalid mnemonic"));
      }
      mnemonic = parts[0];
      bw = parts[1];
      if (!["b", "w"].contains(bw)) {
        erroringLines.add(line.error("Invalid mode, must be b(yte) or w(ord)"));
        continue;
      }
    }
    tentativeTokens.add(Tokens.mnemonic(mnemonic));
    if (bw != "") {
      tentativeTokens.add(Tokens.modeInd(bw == "b"));
    }
    if (["jmp", "jne", "jnz", "jeq", "jz", "jnc", "jlo", "jc", "jhs", "jn", "jge", "jl"].contains(mnemonic)) {
      if (matches.length != 2) {
        erroringLines.add(line.error("Jump instruction must have exactly one argument"));
        continue;
      }
      var arg = matches[1];
      if (re.jmpNumeric.hasMatch(arg)) {
        var match = re.jmpNumeric.firstMatch(arg)!;
        String sign = match.namedGroup("sign") ?? "+";
        String? digits = match.namedGroup("digits")?.toLowerCase();
        String? hex = match.namedGroup("hex")?.toLowerCase();
        if (digits == null && hex == null) {
          erroringLines.add(line.error("Invalid argument for jump instruction"));
          continue;
        }
        int? val;
        if (hex != null) {
          val = int.tryParse(hex, radix: 16);
        } else {
          val = int.tryParse(digits!);
        }
        if (val == null) {
          erroringLines.add(line.error("Invalid argument for jump instruction"));
          continue;
        }
        if (sign == "-") {
          val *= -1;
        } else if (sign != "+") {
          erroringLines.add(line.error("Invalid argument for jump instruction"));
        }
        tentativeTokens.add(Tokens.value(val));
      } else if (re.label.hasMatch(arg)) {
        var match = re.label.firstMatch(arg)!;
        if (match.groupCount != 1) {
          erroringLines.add(line.error("Failed to parse label for jump instruction (invalid characters?)"));
          continue;
        }
        String label = match.group(1)!;
        tentativeTokens.add(Tokens.makeLabelVal(label, localLabelPrefix.peek()));
      } else {
        erroringLines.add(line.error("Invalid argument for jump instruction"));
        continue;
      }
      tokens.addAll(tentativeTokens);
      continue;
    }
    if (matches.length > 1) {
      List<Token>? arg1 = parseArgument(matches[1]);
      if (arg1 == null) {
        erroringLines.add(line.error("Failed to parse argument #1"));
        continue;
      }
      tentativeTokens.addAll(arg1);
    }
    if (matches.length > 2) {
      List<Token>? arg2 = parseArgument(matches[2]);
      if (arg2 == null) {
        erroringLines.add(line.error("Failed to parse argument #2"));
        continue;
      }
      tentativeTokens.addAll(arg2);
    }
    tokens.addAll(tentativeTokens);
  }
  tokens.addAll(dataTokens);
  return _deduplicateLineStarts(tokens);
}

class _LocalPrefixGenerator {
  int _id = 0;
  String next() {
    return "\$${_id++}|";
  }
}

void printTokens(List<Token> tokens) {
  print("${Fore.GREEN}Tokens:${Style.RESET_ALL}");
  for (Token token in tokens) {
    print("  $token");
  }
}

void printTokenizerErrors(List<Pair<Line, String>> erroringLines) {
  print("${Fore.RED}Tokenizer Errors:${Style.RESET_ALL}");
  for (Pair<Line, String> erroringLine in erroringLines) {
    print("${Back.RED}  [${erroringLine.first.num}] (${erroringLine.first.contents}): ${erroringLine.second}${Style.RESET_ALL}");
  }
}

void printInstructionParserErrors(List<Pair<LineId, String>> erroringLines) {
  print("${Fore.RED}Instruction Parser Errors:${Style.RESET_ALL}");
  for (Pair<LineId, String> erroringLine in erroringLines) {
    print("${Back.RED}  [${erroringLine.first}]: ${erroringLine.second}${Style.RESET_ALL}");
  }
}


class TokenStream extends ROStack<Token> {
  TokenStream(super.values);

  void popToNextLine() {
    while (peek().token != Tokens.lineStart) {
      pop();
    }
  }
}

class LabelOrValue {
  String? label;
  int? value;
  bool get hasValue => value != null;

  LabelOrValue.lbl(String this.label);

  LabelOrValue.val(int this.value);

  @override
  String toString() => hasValue ? "$value" : "'$label'";

  int get(Map<String, int> labelAddresses) {
    if (value != null) return value!;
    if (labelAddresses[label!] != null) {
      return labelAddresses[label!]!;
    } else {
      throw "Label '$label' not found";
    }
  }
}

abstract class Operand {
  bool get hasExtensionWord;
  int? get extensionWord;

  int get as;
  int get src;

  int get ad;
  int get dst;

  int? _pc;
  bool? _bw;
  Map<String, int>? _labelAddressMap;

  set pc(int? pc) {
    _pc = pc;
  }

  set bw(bool? bw) {
    _bw = bw;
  }

  set labelAddressMap(Map<String, int>? labelAddressMap) {
    _labelAddressMap = labelAddressMap;
  }
}

/* operand types
argRegd         - register direct
argIdx          - indexed (requires two 'value's (index and register)
argRegi         - register indirect
argRegia        - register indirect autoincrement
argSym          - symbolic
argImm          - immediate
argAbs          - absolute
 */


class OperandRegisterDirect extends Operand {

  final int reg;
  OperandRegisterDirect(this.reg) {
    if (reg < 0 || reg > 15) {
      throw ArgumentError("invalid register value $reg");
    }
  }

  @override
  bool get hasExtensionWord => false;

  @override
  int? get extensionWord => null;

  @override
  int get as => 0;

  @override
  int get src => reg;

  @override
  int get ad => 0;

  @override
  int get dst => reg;

  @override
  String toString() => "RegDir r$reg";
}

class OperandIndexed extends Operand {

  final int reg;
  final LabelOrValue val;

  OperandIndexed(this.reg, this.val) {
    if (reg < 0 || reg > 15) {
      throw ArgumentError("invalid register value $reg");
    }
  }

  @override
  bool get hasExtensionWord => true;

  @override
  int? get extensionWord => val.get(_labelAddressMap!);

  @override
  int get as => 01;

  @override
  int get src => reg;

  @override
  int get ad => 1;

  @override
  int get dst => reg;

  @override
  String toString() => "RegIdx $val(r$reg)";
}

class OperandRegisterIndirect extends Operand {

  final int reg;
  final bool autoincrement;
  OperandRegisterIndirect(this.reg, this.autoincrement) {
    if (reg < 0 || reg > 15) {
      throw ArgumentError("invalid register value $reg");
    }
  }

  @override
  bool get hasExtensionWord => false;

  @override
  int? get extensionWord => null;

  @override
  int get as => autoincrement ? 3 : 2; // 0b11 : 0b10

  @override
  int get src => reg;

  @override
  int get ad => throw UnimplementedError("Indirect mode not supported as destination (@r$reg${autoincrement ? '+' : ''})");

  @override
  int get dst => throw UnimplementedError("Indirect mode not supported as destination (@r$reg${autoincrement ? '+' : ''})");

  @override
  String toString() => "RegInd @r$reg${autoincrement ? '+' : ''}";
}

class OperandSymbolic extends Operand {

  final LabelOrValue val;

  OperandSymbolic(this.val);

  @override
  bool get hasExtensionWord => true;

  @override
  int? get extensionWord => _pc == null ? null : (val.get(_labelAddressMap!) - _pc!); // requires knowledge of Program Counter

  @override
  int get as => 01; // actually indexed mode. shhh! don't tell anyone!

  @override
  int get src => 0; // r0 (pc)

  @override
  int get ad => 1;

  @override
  int get dst => 0;

  @override
  String toString() => "Sym $val";
}


Map<int, Pair<int, int>> specialImmediates = { // value: <as, reg>
  4: Pair(2, 2), // 0b10, 2(sr)
  8: Pair(3, 2), // 0b11, 2(sr)
  0: Pair(0, 3), // 0b00, 3(cg)
  1: Pair(1, 3), // 0b01, 3(cg) (there is no index word)
  2: Pair(2, 3), // 0b10, 3(cg)
  -1: Pair(3, 3) // 0b11, 3(cg)
};


class OperandImmediate extends Operand {

  final LabelOrValue val;

  OperandImmediate(this.val);

  bool get _extensionWordSkippable => val.hasValue && specialImmediates.containsKey(val.value);

  @override
  bool get hasExtensionWord => !_extensionWordSkippable;

  @override
  int? get extensionWord {
    if (_extensionWordSkippable) return null;
    var ext = val.get(_labelAddressMap!);
    return _bw! ? (ext << 8) & 0xff00 : ext; // workaround for the fact that our emulator uses HILO words, rather than LOHI words like the MSP does
  }

  @override
  int get as => _extensionWordSkippable ? specialImmediates[val.value]!.first : 3; // 0b11 actually register autoincrement

  @override
  int get src => _extensionWordSkippable ? specialImmediates[val.value]!.second : 0; // r0 (pc)

  @override
  int get ad => throw UnimplementedError("Immediate mode not supported as destination ($val)");

  @override
  int get dst => throw UnimplementedError("Immediate mode not supported as destination ($val)");

  @override
  String toString() => "Imm #$val";
}

class OperandAbsolute extends Operand {

  final LabelOrValue val;

  OperandAbsolute(this.val);

  @override
  bool get hasExtensionWord => true;

  @override
  int? get extensionWord => val.get(_labelAddressMap!);

  @override
  int get as => 01; // actually indexed mode

  @override
  int get src => 2; // r2 (sr) is specially decoded as '0' for indexed mode

  @override
  int get ad => 1;

  @override
  int get dst => 2;

  @override
  String toString() => "Abs &$val";
}



abstract class Instruction {
  LineId lineNo;
  List<String> labels;
  String mnemonic;
  InstrInfo info;
  Instruction(this.lineNo, this.mnemonic, this.labels, this.info);
  int get numWords;
  Iterable<int> compiled(Map<String, int> labelAddresses, int pc);
}

class PaddingInstruction extends Instruction {
  final int words;
  PaddingInstruction(LineId lineNo, List<String> labels, this.words) : super(LineId(0, lineNo.second), 'padding', labels, nullInfo);

  @override
  Iterable<int> compiled(Map<String, int> labelAddresses, int pc) {
    return List.filled(words, 0, growable: false);
  }

  @override
  int get numWords => words;

  @override
  String toString() => "pad<$words words> $labels";
}

class ListingCommentInstruction extends Instruction {
  final String message;
  ListingCommentInstruction(this.message): super(LineId(-42, "ignore_me"), ';!!', [], nullInfo);

  @override
  Iterable<int> compiled(Map<String, int> labelAddresses, int pc) => const [];

  @override
  int get numWords => 0;

  @override
  String toString() => "listingComment<'$message'>";
}

class JumpInstruction extends Instruction {
  LabelOrValue target;

  JumpInstruction(super.lineNo, super.mnemonic, super.labels, super.info, this.target);

  @override
  String toString() => "$mnemonic->$target $labels";

  @override
  int get numWords => 1;

  @override
  Iterable<int> compiled(Map<String, int> labelAddresses, int pc) {
    // 10 bit signed offset (2s complement)
    num offset = target.get(labelAddresses);
    if (!target.hasValue) {
      offset -= pc;
    }
    offset -= 2;
    offset /= 2;
    if (offset % 1 != 0) {
      throw "Invalid jump offset: must be even";
    }
    int offsetInt = offset.floor();
    if (offset > 512 || offset < -511) {
      throw "Invalid jump offset: must be between -511 and 512 words";
    }
    if (offsetInt < 0) {
      offsetInt += 1024;
    }
    int out = 0x2000; // 0b0010_0000_0000_0000
    int opcode = int.parse(info.opCode, radix: 2);
    out |= (opcode << 10);
    out |= offsetInt;
    return [out];
  }


}

class SingleOperandInstruction extends Instruction {
  Operand op1;
  bool bw;

  SingleOperandInstruction(super.lineNo, super.mnemonic, super.labels, super.info, this.op1, this.bw);

  @override
  String toString() => "$mnemonic<$op1>${info.supportBW ? (bw ? '.b' : '.w') : ''} $labels";

  @override
  int get numWords => 1 + op1.hasExtensionWord.int;

  @override
  Iterable<int> compiled(Map<String, int> labelAddresses, int pc) {
    int out = 0x1000; // 0b0001_0000_0000_0000
    int opcode = int.parse(info.opCode, radix: 2);
    op1.pc = pc + 2;
    op1.bw = bw;
    op1.labelAddressMap = labelAddresses;
    out |= opcode << 7;
    out |= bw.int << 6;
    out |= op1.as << 4;
    out |= op1.src;
    return [out, if (op1.hasExtensionWord) op1.extensionWord!];
  }
}

class DoubleOperandInstruction extends Instruction {
  Operand src;
  Operand dst;
  bool bw;

  DoubleOperandInstruction(super.lineNo, super.mnemonic, super.labels, super.info, this.src, this.dst, this.bw);

  @override
  String toString() => "$mnemonic<$src, $dst>${info.supportBW ? (bw ? '.b' : '.w') : ''} $labels";

  @override
  int get numWords => 1 + src.hasExtensionWord.int + dst.hasExtensionWord.int;

  @override
  Iterable<int> compiled(Map<String, int> labelAddresses, int pc) {
    int out = int.parse(info.opCode, radix: 2) << 12;
    src.pc = pc + 2;
    src.bw = bw;
    dst.pc = pc + (src.hasExtensionWord ? 4 : 2);
    dst.bw = bw;
    src.labelAddressMap = labelAddresses;
    dst.labelAddressMap = labelAddresses;
    out |= src.src << 8;
    out |= dst.ad << 7;
    out |= bw.int << 6;
    out |= src.as << 4;
    out |= dst.dst;
    return [out,
      if (src.hasExtensionWord) src.extensionWord!,
      if (dst.hasExtensionWord) dst.extensionWord!];
  }
}

class RetiInstruction extends Instruction {
  RetiInstruction(LineId lineNo, List<String> labels, InstrInfo info) : super(lineNo, "reti", labels, info);

  @override
  String toString() => "RetiInstruction $labels";

  @override
  int get numWords => 1;

  @override
  Iterable<int> compiled(Map<String, int> labelAddresses, int pc) {
    return [0x1300]; // 0b0001001100000000
  }
}

abstract class DataInstruction extends Instruction {
  DataInstruction(LineId lineNo, List<String> labels) : super(lineNo, "data", labels, nullInfo);
}

// Null byte-terminated C-style string (8 bit chars)
class CString8DataInstruction extends DataInstruction {
  final String value;
  CString8DataInstruction(super.lineNo, super.labels, {required this.value}) {
    for (int char in value.codeUnits) {
      int truncated = char & 0xff;
      if (truncated != char) {
        throw RangeError("Character out of range for 8-bit cString");
      }
    }
  }

  @override
  Iterable<int> compiled(Map<String, int> labelAddresses, int pc) {
    List<int> byteParts = List.filled(value.length + 1, 0);
    int i = 0;
    for (int char in value.codeUnits) {
      byteParts[i] = char & 0xff;
      i++;
    }

    List<int> wordParts = List.filled(numWords, 0);
    for (int i = 0; i < wordParts.length; i++) {
      int firstIdx = i * 2;
      int secondIdx = firstIdx + 1;
      int word = byteParts[firstIdx] << 8;
      if (secondIdx < byteParts.length) {
        word += byteParts[secondIdx];
      }

      wordParts[i] = word;
    }
    return wordParts;
  }

  @override
  int get numWords => ((value.length + 1.0) / 2.0).ceil();

  @override
  String toString() {
    return ".cstr8 '$value' $labels";
  }
}

class InterruptInstruction extends DataInstruction {
  int vector;
  LabelOrValue value;
  InterruptInstruction(LineId lineNo, this.vector, this.value) : super(lineNo, []);

  @override
  Iterable<int> compiled(Map<String, int> labelAddresses, int pc) {
    throw "Interrupt instructions should not be compiled, they are a special case";
  }

  @override
  int get numWords => 0;
  
  @override
  String toString() {
    return ".interrupt '$vector'->$value";
  }
}


class InstrInfo {
  final String opCode;
  final int argCount; // 0 is just for regi, 1 is single-operand arithmetic, 2 is two-operand arithmetic, -1 is jump
  final bool supportBW;

  String? _mnemonic;
  String get mnemonic => _mnemonic ?? "???";
  void setMnemonicOnce(String mnemonic) {
    _mnemonic ??= mnemonic;
  }
  InstrInfo(this.argCount, this.opCode, [this.supportBW = true]);
}

final InstrInfo nullInfo = InstrInfo(0, "");

class EmulatedInstrInfo extends InstrInfo {
  late final bool hasBW;
  late final String source;
  late final String dest;
  late final bool isJMP;
  EmulatedInstrInfo(String data) : super(data.contains("dst") ? 1 : 0, 'unparsed emulated instruction') { // data looks like this: "ADC.x dst	ADDC.x #0,dst"
    List<String> split = data.split("\t");
    source = split[0];
    dest = split[1];
    isJMP = instructionInfo[dest.split(" ")[0].toLowerCase()]?.argCount == -1;

    hasBW = source.contains(".x");
  }
}

final String emulatedInstructions = """
ADC.x dst	ADDC.x #0,dst
BR dst	MOV dst,PC
CLR.x dst	MOV.x #0,dst
CLRC	BIC #1,SR
CLRN	BIC #4,SR
CLRZ	BIC #2,SR
DADC.x dst	DADD.x #0,dst
DEC.x dst	SUB.x #1,dst
DECD.x dst	SUB.x #2,dst
DINT	BIC #8,SR
EINT	BIS #8,SR
INC.x dst	ADD.x #1,dst
INCD.x dst	ADD.x #2,dst
INV.x dst	XOR.x #−1,dst
NOP	MOV #0,R3
POP dst	MOV @SP+,dst
RET	MOV @SP+,PC
RLA.x dst	ADD.x dst,dst
RLC.x dst	ADDC.x dst,dst
SBC.x dst	SUBC.x #0,dst
SETC	BIS #1,SR
SETN	BIS #4,SR
SETZ	BIS #2,SR
TST.x dst	CMP.x #0,dst
HCF	JMP 0
""";

final Map<String, InstrInfo> instructionInfo = {
  "rrc": InstrInfo(1, "000", true),
  "swpb": InstrInfo(1, "001", false),
  "rra": InstrInfo(1, "010", true),
  "sxt": InstrInfo(1, "011", false),
  "push": InstrInfo(1, "100", true),
  "call": InstrInfo(1, "101", false),
  "reti": InstrInfo(0, "110", false),


  "jne": InstrInfo(-1, "000", false), // jnz
  "jnz": InstrInfo(-1, "000", false), // jnz

  "jeq": InstrInfo(-1, "001", false), // jz
  "jz": InstrInfo(-1, "001", false),  // jz

  "jnc": InstrInfo(-1, "010", false), // jlo
  "jlo": InstrInfo(-1, "010", false), // jlo

  "jc": InstrInfo(-1, "011", false),  // jhs
  "jhs": InstrInfo(-1, "011", false), // jhs

  "jn": InstrInfo(-1, "100", false),
  "jge": InstrInfo(-1, "101", false),
  "jl": InstrInfo(-1, "110", false),
  "jmp": InstrInfo(-1, "111", false),


  "mov": InstrInfo(2, "0100", true),
  "add": InstrInfo(2, "0101", true),
  "addc": InstrInfo(2, "0110", true),
  "subc": InstrInfo(2, "0111", true),
  "sub": InstrInfo(2, "1000", true),
  "cmp": InstrInfo(2, "1001", true),
  "dadd": InstrInfo(2, "1010", true),
  "bit": InstrInfo(2, "1011", true),
  "bic": InstrInfo(2, "1100", true),
  "bis": InstrInfo(2, "1101", true),
  "xor": InstrInfo(2, "1110", true),
  "and": InstrInfo(2, "1111", true),
};


bool _instructionsInitialized = false;

void initInstructionInfo() {
  if (_instructionsInitialized) {
    return;
  }
  _instructionsInitialized = true;
  for (String emulated in emulatedInstructions.split("\n")) {
    if (emulated == "") {
      continue;
    }
    String mnemonic = emulated.split("\t")[0].replaceAll(" dst", "").replaceAll(".x", "").toLowerCase();
    instructionInfo[mnemonic] = EmulatedInstrInfo(emulated);
  }
  
  for (MapEntry<String, InstrInfo> entry in instructionInfo.entries) {
    entry.value.setMnemonicOnce(entry.key);
  }
}

Operand? parseOperandFromStream(Token nextArg, TokenStream t, Function(String, Token) fail) {
  switch (nextArg.token) {
    case Tokens.argRegd: // stream looks like [next] [val]
      Token nextV = t.peek();
      if (!nextV.isVal) {
        fail("value", nextV);
        return null;
      }
      t.pop();
      return OperandRegisterDirect(nextV.value);
    case Tokens.argIdx: //[Tokens.argIdx(), Tokens.value(idx), Tokens.value(regNum)]; or [Tokens.argIdx(), Tokens.labelVal(lbl), Tokens.value(regNum)];
      Token nextV = t.peek();
      LabelOrValue lv;
      if (nextV.isVal) {
        lv = LabelOrValue.val(nextV.value);
      } else if (nextV.isLblVal) {
        lv = LabelOrValue.lbl(nextV.value);
      } else {
        fail("value or labelVal", nextV);
        return null;
      }
      t.pop(); // pop nextV
      Token nextReg = t.peek();
      if (!nextReg.isVal) {
        fail("value", nextReg);
        return null;
      }
      t.pop();
      return OperandIndexed(nextReg.value, lv);
    case Tokens.argRegi: case Tokens.argRegia: // [next] [val]
    Token nextV = t.peek();
    if (!nextV.isVal) {
      fail("value", nextV);
      return null;
    }
    t.pop();
    return OperandRegisterIndirect(nextV.value, nextArg.token == Tokens.argRegia);
    case Tokens.argSym: // [next] [val/lblVal]
      Token nextV = t.peek();
      LabelOrValue lv;
      if (nextV.isVal) {
        lv = LabelOrValue.val(nextV.value);
      } else if (nextV.isLblVal) {
        lv = LabelOrValue.lbl(nextV.value);
      } else {
        fail("value or labelVal", nextV);
        return null;
      }
      t.pop();
      return OperandSymbolic(lv);
    case Tokens.argImm: // [next] [val/lblVal]
      Token nextV = t.peek();
      LabelOrValue lv;
      if (nextV.isVal) {
        lv = LabelOrValue.val(nextV.value);
      } else if (nextV.isLblVal) {
        lv = LabelOrValue.lbl(nextV.value);
      } else {
        fail("value or labelVal", nextV);
        return null;
      }
      t.pop();
      return OperandImmediate(lv);
    case Tokens.argAbs: // [next] [val/lblVal]
      Token nextV = t.peek();
      LabelOrValue lv;
      if (nextV.isVal) {
        lv = LabelOrValue.val(nextV.value);
      } else if (nextV.isLblVal) {
        lv = LabelOrValue.lbl(nextV.value);
      } else {
        fail("value or labelVal", nextV);
        return null;
      }
      t.pop();
      return OperandAbsolute(lv);
    default:
      throw AssertionError("Unreachable clause reached somehow.");
  }
}


// This should be implemented somewhat like a state machine (described in parse_fsm.xcf)
List<Instruction> parseInstructions(List<Token> tokens, List<Pair<LineId, String>> erroringLines, [String fileName = ""]) {
  TokenStream t = TokenStream(tokens);
  LineId line = LineId(0, fileName);
  List<Instruction> instructions = [];
  List<String> labels = [];
  bool dataMode = false;
  while (t.isNotEmpty) {
    Token token = t.pop();
    if (token.token == Tokens.lineStart) {
      line = token.value;
    } else if (token.token == Tokens.label) {
      labels.add(token.value);
    } else if (token.token == Tokens.dbgBreak) {
      instructions.add(PaddingInstruction(line, [], 0));
    } else if (token.token == Tokens.listingComment) {
      instructions.add(ListingCommentInstruction(token.value));
    } else if (token.token == Tokens.interrupt) {
      labels = [];
      int vector = token.value;
      Token next = t.peek();
      if (next.token != Tokens.labelVal) {
        erroringLines.add(Pair(line, "Invalid token after interrupt instruction, expected label, got $next"));
        t.popToNextLine();
        continue;
      }
      t.pop(); // pop labelVal
      instructions.add(InterruptInstruction(line, vector, LabelOrValue.lbl(next.value)));
    } else if (token.token == Tokens.dataMode) {
      dataMode = true;
      labels = [];
    } else if (dataMode && token.token == Tokens.cString8Data) {
      String value = token.value;
      try {
        instructions.add(CString8DataInstruction(line, labels, value: value));
      } on RangeError {
        erroringLines.add(Pair(line, "Out-of-range character in `$value`"));
      }
      labels = [];
      t.popToNextLine();
      continue;
    } else if (!dataMode && token.token == Tokens.mnemonic) {
      // parsing hell
      String mnemonic = token.value;
      InstrInfo? info = instructionInfo[mnemonic];
      if (info == null) {
        erroringLines.add(Pair(line, "Unknown mnemonic $mnemonic"));
        labels = [];
        t.popToNextLine();
        continue;
      }
      if (info is EmulatedInstrInfo) {
        Token next = t.peek();
        bool bw = false;
        if (next.token == Tokens.modeInd) {
          if (!info.hasBW) {
            erroringLines.add(Pair(line, "Emulated mnemonic $mnemonic doesn't take a byte/word indicator"));
            labels = [];
            t.popToNextLine();
            continue;
          }
          bw = next.value;
          t.pop(); // pop mode indicator
          next = t.peek();
        }
        if (next.token.isArg) {
          t.pop(); // pop argument
          if (info.argCount != 1) {
            erroringLines.add(Pair(line, "Emulated mnemonic $mnemonic doesn't accept any arguments"));
            labels = [];
            t.popToNextLine();
            continue;
          }

          void fail(String expected, Token got) {
            erroringLines.add(Pair(line, "Invalid token during emulated mnemonic arg parsing, expected $expected, got $got"));
            labels = [];
            t.popToNextLine();
          }

          String targetMnemonic = info.dest.split(" ")[0].replaceAll(".x", "").toLowerCase();
          Couple<String> args = info.dest.split(" ")[1].split(",").toCouple();

          Operand? operand = parseOperandFromStream(next, t, fail);

          Operand? op1;
          Operand? op2;
          if (args.first == "dst") {
            op1 = operand;
          } else {
            var parsed = parseArgument(args.first);
            if (parsed == null) {
              erroringLines.add(Pair(line, "Failed to parse one or more operand tokens in emulated"));
              labels = [];
              t.popToNextLine();
              continue;
            }
            TokenStream argTokens = TokenStream(parsed);
            op1 = parseOperandFromStream(argTokens.pop(), argTokens, fail);
          }
          if (args.second == "dst") {
            op2 = operand;
          } else {
            var parsed = parseArgument(args.second);
            if (parsed == null) {
              erroringLines.add(Pair(line, "Failed to parse one or more operand tokens in emulated"));
              labels = [];
              t.popToNextLine();
              continue;
            }
            TokenStream argTokens = TokenStream(parsed);
            op2 = parseOperandFromStream(argTokens.pop(), argTokens, fail);
          }
          if (op1 == null || op2 == null) {
            erroringLines.add(Pair(line, "Emulated mnemonic $mnemonic failed to parse target operands"));
            labels = [];
            t.popToNextLine();
            continue;
          }
          instructions.add(DoubleOperandInstruction(line, targetMnemonic, labels, instructionInfo[targetMnemonic]!, op1, op2, bw));
          labels = [];
          continue;
        } else if (info.argCount == 1) {
          erroringLines.add(Pair(line, "Emulated mnemonic $mnemonic expects an argument"));
          labels = [];
          t.popToNextLine();
          continue;
        }
        // we now have enough to build an instruction without args
        String targetMnemonic = info.dest.split(" ")[0].replaceAll(".x", "").toLowerCase();
        if (info.isJMP) {
          int val = int.parse(info.dest.split(" ")[1]);
          instructions.add(JumpInstruction(line, targetMnemonic, labels, instructionInfo[targetMnemonic]!, LabelOrValue.val(val)));
          labels = [];
          continue;
        }
        Couple<String> args = info.dest.split(" ")[1].split(",").toCouple();
        Couple<TokenStream> argTokens = args.map((String arg) => TokenStream(parseArgument(arg) ?? []));
        if (argTokens.either((op) => op.isEmpty)) {
          erroringLines.add(Pair(line, "Failed to parse one or more operand tokens in emulated"));
          labels = [];
          t.popToNextLine();
          continue;
        }
        void fail(String expected, Token got) {
          erroringLines.add(Pair(line, "Invalid token during emulated mnemonic arg parsing, expected $expected, got $got"));
          labels = [];
          t.popToNextLine();
        }
        Couple<Operand?> operands = argTokens.map((TokenStream stream) => parseOperandFromStream(stream.pop(), stream, fail));
        if (operands.either((op) => op == null)) {
          erroringLines.add(Pair(line, "Failed to parse one or more operands in emulated"));
          labels = [];
          t.popToNextLine();
          continue;
        }
        instructions.add(DoubleOperandInstruction(line, targetMnemonic, labels, instructionInfo[targetMnemonic]!, operands.first!, operands.second!, bw));
//        print("next after emulated: $next");
        labels = [];
        continue;
      }
      // check for number of arguments etc - special case for jump
      if (info.argCount == -1) { // jump
        Token next = t.peek();
        if (next.token == Tokens.value) {
          t.pop();
          instructions.add(JumpInstruction(line, mnemonic, labels, info, LabelOrValue.val(next.value)));
          labels = [];
          continue;
        } else if (next.token == Tokens.labelVal) {
          t.pop();
          instructions.add(JumpInstruction(line, mnemonic, labels, info, LabelOrValue.lbl(next.value)));
          labels = [];
          continue;
        } else {
          erroringLines.add(Pair(line, "Jump instruction expected a value or labelVal token, got $next"));
          labels = [];
          t.popToNextLine();
          continue;
        }
      } else if (info.argCount == 0) {
        instructions.add(RetiInstruction(line, labels, info));
        labels = [];
        continue;
      } else if (info.argCount == 1) {
        Token next = t.peek();
        bool bw = false;
        if (next.token == Tokens.modeInd) {
          bw = t.pop().value;
          next = t.peek();
        }
        if (next.isArg) {
          t.pop();
          void fail(String expected, Token got) {
            erroringLines.add(Pair(line, "Invalid token during arg parsing, expected $expected, got $got"));
            labels = [];
            t.popToNextLine();
          }
          Operand? op1 = parseOperandFromStream(next, t, fail);
          if (op1 != null) {
            instructions.add(SingleOperandInstruction(line, mnemonic, labels, info, op1, bw));
            labels = [];
          }
          continue;
        } else {
          erroringLines.add(Pair(line, "Single arg instruction expected an argument, got $next"));
          labels = [];
          t.popToNextLine();
          continue;
        }
      } else if (info.argCount == 2) {
        Operand op1;
        Operand op2;

        Token next = t.peek();
        bool bw = false;
        if (next.token == Tokens.modeInd) {
          bw = t.pop().value;
          next = t.peek();
        }
        if (next.isArg) {
          t.pop();
          void fail(String expected, Token got) {
            erroringLines.add(Pair(line, "Invalid token during arg parsing, expected $expected, got $got"));
            labels = [];
            t.popToNextLine();
          }
          Operand? op = parseOperandFromStream(next, t, fail);
          if (op != null) {
            op1 = op;
          } else {
            continue;
          }
        } else {
          erroringLines.add(Pair(line, "Double arg instruction expected a first argument, got $next"));
          labels = [];
          t.popToNextLine();
          continue;
        }

        next = t.peek();
        if (next.isArg) {
          t.pop();
          void fail(String expected, Token got) {
            erroringLines.add(Pair(line, "Invalid token during arg parsing, expected $expected, got $got"));
            labels = [];
            t.popToNextLine();
          }
          Operand? op = parseOperandFromStream(next, t, fail);
          if (op != null) {
            op2 = op;
          } else {
            continue;
          }
        } else {
          erroringLines.add(Pair(line, "Double arg instruction expected a second argument, got $next"));
          labels = [];
          t.popToNextLine();
          continue;
        }
        instructions.add(DoubleOperandInstruction(line, mnemonic, labels, info, op1, op2, bw));
        labels = [];
        continue;
      } else {
        throw AssertionError("Invalid number of arguments");
      }
    } else {
      erroringLines.add(Pair(line, "Unexpected token $token"));
      labels = [];
      t.popToNextLine();
    }
  }
  return instructions;
}


void printInstructions(List<Instruction> instructions) {
  print("Instructions:");
  for (Instruction instruction in instructions) {
    print("  $instruction");
  }
}


Pair<Map<LineId, int>, Map<String, int>> calculateAddresses(int pcStart, List<Instruction> instructions) {
  Map<LineId, int> lineToAddress = {};
  Map<String, int> lblToAddress = {};

  int pc = pcStart;

  for (Instruction instruction in instructions) {
    lineToAddress[instruction.lineNo] = pc;
    for (String label in instruction.labels) {
      lblToAddress[label] = pc;
    }
    pc += instruction.numWords * 2;
  }

  return Pair(lineToAddress, lblToAddress);
}

class BinarySegment {
  final int start;
  int get wordCount => contents.length;
  final List<int> contents; // each entry is WORD
  List<int> get byteContents => contents.expand((int word) => [(word & 0xff00) >> 8, word & 0xff]).toList();
  int get end => start + (wordCount * 2);

  BinarySegment({required this.start, required this.contents});
}

class ListingEntry {
  final int pc;
  final LineId line;
  final String original;
  final List<String> labels;
  final List<int> words;

  const ListingEntry({required this.pc, required this.line, required this.original, required this.labels, required this.words});

  String get _paddedWords {
    List<String> out = [];
    for (int i = 0; i < 3; i++) {
      if (i < words.length) {
        out.add(words[i].hexString4);
      } else {
        out.add(" "*4);
      }
    }
    return out.join(" ");
  }

  String output() {
    return "0x${pc.hexString4}\t$_paddedWords\t${original.padRight(20)}${labels.isEmpty ? "" : "\t$labels"}";
  }
}

class CommentEntry extends ListingEntry {
  const CommentEntry({required super.pc, required super.original}):
        super(line: const LineId(0, "ignore_me"), labels: const [], words: const []);

  @override
  List<String> get labels => [];

  @override
  String output() => "${6.spaces}\t${14.spaces}\t${20.spaces};!!$original";

  @override
  List<int> get words => [];

  @override
  String get _paddedWords => throw UnimplementedError();
}

class ListingGenerator {
  final List<ListingEntry> entries = [];
  final List<int> _pcBreaks = [];
  final Map<LineId, String> _lines;

  ListingGenerator({required List<Line> lines}) : _lines = lines.lineMap;

  void addComment(String text, int pc) {
    entries.add(CommentEntry(pc: pc, original: text));
  }

  void addInstruction(Instruction instr, Map<String, int> labelAddresses, int pc) {
    if (instr is ListingCommentInstruction) {
      addComment(instr.message, pc);
    } else {
      ListingEntry entry = ListingEntry(
          pc: pc,
          line: instr.lineNo,
          original: _lines[instr.lineNo] ?? "{LINE CONTENTS NOT FOUND}",
          labels: instr.labels,
          words: instr.compiled(labelAddresses, pc).toList(growable: false)
      );
      entries.add(entry);
    }
  }

  void breakAt(int pc) {
    _pcBreaks.add(pc);
  }

  String output() {
    entries.sort((a, b) => a.pc.compareTo(b.pc));
    _pcBreaks.sort();
    List<String> out = [];

    // label section
    out.add("------------|Labels|------------");

    List<String> labels = [];
    Map<String, int> labelAddresses = {};
    for (ListingEntry entry in entries) {
      for (String label in entry.labels) {
        if (!labels.contains(label)) {
          labels.add(label);
          labelAddresses[label] = entry.pc;
        }
      }
    }
    labels.sort();
    for (String label in labels) {
      out.add("${label.padRight(20)}\t0x${labelAddresses[label]!.hexString4}");
    }

    // code section
    out.add("\n-------------|Code|-------------");

    int breakIdx = 0;
    int nextBreak = _pcBreaks.isEmpty ? -2 : _pcBreaks[breakIdx];
    for (ListingEntry entry in entries) {
      if (entry.pc == nextBreak) {
        out.add("");
        breakIdx += 1;
        if (breakIdx >= _pcBreaks.length) {
          nextBreak = -2;
        } else {
          nextBreak = _pcBreaks[breakIdx];
        }
      }
      out.add(entry.output());
    }

    // line map section
    out.add("\n-----------|Line Map|-----------");
    // (line, (pc, (word...)))
    List<Pair<int, Pair<int, List<int>>>> lineMap = [];
    for (ListingEntry entry in entries) {
      if (entry.line.second == "") {
        lineMap.add(Pair(entry.line.first, Pair(entry.pc, entry.words)));
      }
    }
    lineMap.sort((a, b) => a.first.compareTo(b.first));
    for (Pair<int, Pair<int, List<int>>> entry in lineMap) {
      out.add("${entry.first}\t0x${entry.second.first.hexString4}\t${entry.second.second.map((int word) => word.hexString4).join(" ")}");
    }

    return "${out.join("\n")}\n";
  }
}


Uint8List compile(
    int pcStart,
    List<Instruction> instructions,
    Map<String, int> labelAddresses,
    {void Function(Map<LineId, String>)? errorConsumer, ListingGenerator? listing}
    ) {
  Map<LineId, String> errors = {};
  List<BinarySegment> segments = [];
  List<BinarySegment> postFixSegments = [];
  BinarySegment currentSegment = BinarySegment(start: pcStart, contents: []);
  int pc = pcStart;
  for (Instruction instruction in instructions) {
    if (instruction is PaddingInstruction) {
      if (currentSegment.contents.isNotEmpty) {
        segments.add(currentSegment);
      }
      listing?.breakAt(pc);
      pc += instruction.numWords * 2;
      currentSegment = BinarySegment(start: pc, contents: []);
    } else if (instruction is InterruptInstruction) {
      postFixSegments.add(BinarySegment(start: instruction.vector, contents: [instruction.value.get(labelAddresses)]));
    } else {
      try {
        listing?.addInstruction(instruction, labelAddresses, pc);
        currentSegment.contents.addAll(instruction.compiled(labelAddresses, pc));
      } catch (e) {
        var errorDescription = e is UnimplementedError ? e.message : e;
        if (errorConsumer == null) {
          print("\n\n\nError compiling $instruction (pc $pc) $errorDescription");
          rethrow;
        } else {
          errors[instruction.lineNo] = "Cannot compile $instruction (pc $pc) $errorDescription";
        }
      }
      pc += instruction.numWords * 2;
    }
  }

  if (currentSegment.contents.isNotEmpty) {
    segments.add(currentSegment);
  }

  segments.add(BinarySegment(start: 0xfffe, contents: [pcStart])); // startup interrupt vector
  segments.addAll(postFixSegments);

  segments.sort((BinarySegment a, BinarySegment b) => a.start.compareTo(b.start));

  if (errors.isNotEmpty && errorConsumer != null) {
    errorConsumer(errors);
    throw "Errors found during compilation";
  }

  // merge adjacent segments
  bool merged = true;
  List<BinarySegment> newSegments = segments;
  while (merged) {
    merged = false;
    segments = newSegments;
    newSegments = [];
    int? lastEnd;

    for (BinarySegment segment in segments) {
      if (lastEnd == segment.start) {
        newSegments.last.contents.addAll(segment.contents);
        merged = true;
      } else {
        newSegments.add(segment);
      }
      lastEnd = segment.end;
    }
  }

  List<int> out = [
    0xff, 0xff, // format marker
    (segments.length & 0xff00) >> 8, segments.length & 0xff, // segment count
    for (BinarySegment segment in segments)
      ...[
        (segment.start & 0xff00) >> 8, segment.start & 0xff, // segment start
        ((segment.wordCount*2) & 0xff00) >> 8, (segment.wordCount*2) & 0xff, // segment length (bytes)
        ...segment.byteContents,
      ],
  ];

  return Uint8List.fromList(out);
}


Uint8List? parse(String txt, {int codeStart = 0x4400, bool silent = false, void Function(Map<LineId, String>)? errorConsumer, Directory? containingDirectory, MutableObject<ListingGenerator>? listingGen}) {
  initInstructionInfo();
  List<Line> lines = parseLines(txt, containingDirectory: containingDirectory);

  List<Pair<Line, String>> erroringLines = <Pair<Line, String>>[].onAdd((v) {
    if (_panicOnRecursionLimit.depth > 0 && v.second == "macro expansion recursion limit reached") {
      throw MacroRecursionError(v.first);
    }
  });

  lines = parseIncludeErrors(lines, erroringLines);
  lines = parseDefines(lines, erroringLines);
  lines = parseMacros(lines, erroringLines);

  if (listingGen != null) {
    listingGen.set(ListingGenerator(lines: lines));
  }

  List<Token> tokens = parseTokens(lines, erroringLines);

  if (!silent) {
    printTokenizerErrors(erroringLines);
    printTokens(tokens);
  }

  List<Pair<LineId, String>> instructionParserErrors = [];
  List<Instruction> instructions = parseInstructions(tokens, instructionParserErrors);

  if (!silent) {
    printInstructionParserErrors(instructionParserErrors);
    printInstructions(instructions);
  }

  Pair<Map<LineId, int>, Map<String, int>> addressMaps = calculateAddresses(codeStart, instructions); // <{line:addr}, {lbl:addr}>

  Map<String, int> labelAddresses = addressMaps.second;

  Map<LineId, String> errors = {};
  for (Pair<Line, String> erroringLine in erroringLines) { // tokenizer errors
    errors[erroringLine.first.num] = erroringLine.second;
  }
  for (Pair<LineId, String> erroringLine in instructionParserErrors) { // instruction parser errors
    if (!errors.containsKey(erroringLine.first)) {
      errors[erroringLine.first] = erroringLine.second;
    }
  }

  if (errorConsumer != null) {
    errorConsumer(errors);
  }

  try {
    if (errors.isNotEmpty) {
      throw "Errors found, can't compile";
    }
    return compile(codeStart, instructions, labelAddresses, errorConsumer: errorConsumer, listing: listingGen?.get());
  } catch (e) {
    return null;
  }
}

Future<void> writeCompiledByName(Uint8List compiled, String fileName) async {
  var out = File(fileName);
  await out.writeAsBytes(compiled, flush: true);
}

Future<void> writeCompiled(Uint8List compiled, File file) async {
  await file.writeAsBytes(compiled, flush: true);
}

R executeWithPanicOnRecursionLimit<R>(R Function() callback) {
  _panicOnRecursionLimit.enter();
  final R ret;
  try {
    ret = callback();
  } finally {
    _panicOnRecursionLimit.exit();
  }
  return ret;
}