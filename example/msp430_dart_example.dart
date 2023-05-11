import 'package:msp430_dart/msp430_dart.dart';

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
modeInd         - byte/word indicator (true = word, false = byte)
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


class Line {
  final int num;
  final String contents;
  Line(this.num, this.contents);

  Line set(String contents) => Line(num, contents);

  Pair<Line, String> error(String error) => Pair(this, error);
}


enum Tokens<T> {
  lineStart<int>(0),
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
  ;
  final T _sham;
  const Tokens(this._sham);

  Token<T> call([T? value]) {
    if ((value == null) != (T == Null || _sham == null)) {
      throw AssertionError("$this requires an argument of type $T");
    }
    return Token<T>(this, value);
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
    }
    return '$color${token.name}<$T>[$value]${Style.RESET_ALL}';
  }

  bool get isArg => token.isArg;

  bool get isVal => token.isVal;

  bool get isLblVal => token.isLblVal;
}


List<Line> parseLines(String txt) {
  List<String> strings = txt.split("\n");
  List<Line> lines = [];
  for (int i = 0; i < strings.length; i++) {
    lines.add(Line(i, strings[i]));
  }
  return lines;
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

List<Token> parseTokens(List<Line> lines, List<Pair<Line, String>> erroringLines) {
  List<Token> tokens = [];
  for (Line line in lines) {
    List<Token> tentativeTokens = [];
    tentativeTokens.add(Tokens.lineStart(line.num));
    String val = line.contents.trim();
    if (val.contains(";")) {
      val = val.split(";")[0];
    }
    if (val == "") {
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
      tentativeTokens.add(Tokens.label(label));
      if (val == '') {
        tokens.addAll(tentativeTokens);
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
      tentativeTokens.add(Tokens.modeInd(bw == "w"));
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
        tentativeTokens.add(Tokens.labelVal(label));
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
  return tokens;
}

void printTokens(List<Token> tokens) {
  print("${Fore.GREEN}Tokens:${Style.RESET_ALL}");
  for (Token token in tokens) {
    print("  $token");
  }
}

void printErrors(List<Pair<Line, String>> erroringLines) {
  print("${Fore.RED}Errors:${Style.RESET_ALL}");
  for (Pair<Line, String> erroringLine in erroringLines) {
    print("${Back.RED}  [${erroringLine.first.num}] (${erroringLine.first.contents}): ${erroringLine.second}${Style.RESET_ALL}");
  }
}


class TokenStream {
  late final List<Token> _tokens;
  TokenStream(List<Token> tokens) {
    _tokens = tokens.toList();
  }

  Token peek() {
    return _tokens[0];
  }

  Token peekAhead(int idx) {
    return _tokens[idx];
  }

  Token pop() {
    return _tokens.removeAt(0);
  }

  bool get isEmpty => _tokens.isEmpty;

  bool get isNotEmpty => _tokens.isNotEmpty;

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
}

abstract class Operand {
  bool get hasExtensionWord;
  int? get extensionWord;

  int get as;
  int get src;

  int get ad;
  int get dst;

  int? _pc = null;

  set pc(int? pc) {
    _pc = pc;
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

  final int _reg;
  OperandRegisterDirect(this._reg) {
    if (_reg < 0 || _reg > 15) {
      throw ArgumentError("invalid register value $_reg");
    }
  }

  @override
  bool get hasExtensionWord => false;

  @override
  int? get extensionWord => null;

  @override
  int get as => 0;

  @override
  int get src => _reg;

  @override
  int get ad => 0;

  @override
  int get dst => _reg;

  @override
  String toString() => "RegDir r$_reg";
}

class OperandIndexed extends Operand {

  final int _reg;
  final LabelOrValue _val;

  OperandIndexed(this._reg, this._val) {
    if (_reg < 0 || _reg > 15) {
      throw ArgumentError("invalid register value $_reg");
    }
  }

  @override
  bool get hasExtensionWord => true;

  @override
  int? get extensionWord => _val.value;

  @override
  int get as => 01;

  @override
  int get src => _reg;

  @override
  int get ad => 1;

  @override
  int get dst => _reg;

  @override
  String toString() => "RegIdx $_val(r$_reg)";
}

class OperandRegisterIndirect extends Operand {

  final int _reg;
  final bool _autoincrement;
  OperandRegisterIndirect(this._reg, this._autoincrement) {
    if (_reg < 0 || _reg > 15) {
      throw ArgumentError("invalid register value $_reg");
    }
  }

  @override
  bool get hasExtensionWord => false;

  @override
  int? get extensionWord => null;

  @override
  int get as => _autoincrement ? 3 : 2; // 0b11 : 0b10

  @override
  int get src => _reg;

  @override
  int get ad => throw UnimplementedError();

  @override
  int get dst => throw UnimplementedError();

  @override
  String toString() => "RegInd @r$_reg${_autoincrement ? '+' : ''}";
}

class OperandSymbolic extends Operand {

  final LabelOrValue _val;

  OperandSymbolic(this._val);

  @override
  bool get hasExtensionWord => true;

  @override
  int? get extensionWord => _pc == null ? null : (_val.hasValue ? _val.value! - _pc! : null); // requires knowledge of Program Counter

  @override
  int get as => 01; // actually indexed mode. shhh! don't tell anyone!

  @override
  int get src => 0; // r0 (pc)

  @override
  int get ad => 1;

  @override
  int get dst => 0;

  @override
  String toString() => "Sym $_val";
}

class OperandImmediate extends Operand {

  final LabelOrValue _val;

  OperandImmediate(this._val);

  @override
  bool get hasExtensionWord => true;

  @override
  int? get extensionWord => _val.value;

  @override
  int get as => 3; // 0b11 actually register autoincrement

  @override
  int get src => 0; // r0 (pc)

  @override
  int get ad => throw UnimplementedError();

  @override
  int get dst => throw UnimplementedError();

  @override
  String toString() => "Imm #$_val";
}

class OperandAbsolute extends Operand {

  final LabelOrValue _val;

  OperandAbsolute(this._val);

  @override
  bool get hasExtensionWord => true;

  @override
  int? get extensionWord => _val.value;

  @override
  int get as => 01; // actually indexed mode

  @override
  int get src => 2; // r2 (sr) is specially decoded as '0' for indexed mode

  @override
  int get ad => 1;

  @override
  int get dst => 2;

  @override
  String toString() => "Abs &$_val";
}



class Instruction {
  List<String> labels;
  String mnemonic;
  InstrInfo info;
  Instruction(this.mnemonic, this.labels, this.info);
}

class JumpInstruction extends Instruction {
  LabelOrValue target;

  JumpInstruction(super.mnemonic, super.labels, super.info, this.target);

  @override
  String toString() => "$mnemonic->$target $labels";
}

class SingleOperandInstruction extends Instruction {
  Operand op1;

  SingleOperandInstruction(super.mnemonic, super.labels, super.info, this.op1);

  @override
  String toString() => "$mnemonic<$op1> $labels";
}

class DoubleOperandInstruction extends Instruction {
  Operand op1;
  Operand op2;

  DoubleOperandInstruction(super.mnemonic, super.labels, super.info, this.op1, this.op2);

  @override
  String toString() => "$mnemonic<$op1, $op2> $labels";
}

class RetiInstruction extends Instruction {
  RetiInstruction(List<String> labels, InstrInfo info) : super("reti", labels, info);

  @override
  String toString() => "RetiInstruction $labels";
}


class InstrInfo {
  final String opCode;
  final int argCount; // 0 is just for regi, 1 is single-operand arithmetic, 2 is two-operand arithmetic, -1 is jump
  final bool supportBW;
  const InstrInfo(this.argCount, this.opCode, [this.supportBW = true]);
}

Map<String, InstrInfo> instructionInfo = {
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


Operand? parseOperandFromStream(Token next, TokenStream t, Function(String, Token) fail) {
  switch (next.token) {
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
    return OperandRegisterIndirect(nextV.value, next.token == Tokens.argRegia);
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
List<Instruction> parseInstructions(List<Token> tokens, List<Pair<int, String>> erroringLines) {
  TokenStream t = TokenStream(tokens);
  int line = 0;
  List<Instruction> instructions = [];
  List<String> labels = [];
  while (t.isNotEmpty) {
    Token token = t.pop();
    if (token.token == Tokens.lineStart) {
      line = token.value;
    } else if (token.token == Tokens.label) {
      labels.add(token.value);
    } else if (token.token == Tokens.mnemonic) {
      // parsing hell
      String mnemonic = token.value;
      InstrInfo? info = instructionInfo[mnemonic];
      if (info == null) {
        erroringLines.add(Pair(line, "Unknown mnemonic $mnemonic"));
        labels = [];
        t.popToNextLine();
        continue;
      }
      // check for number of arguments etc - special case for jump
      if (info.argCount == -1) { // jump
        Token next = t.peek();
        if (next.token == Tokens.value) {
          t.pop();
          instructions.add(JumpInstruction(mnemonic, labels, info, LabelOrValue.val(next.value)));
          labels = [];
          continue;
        } else if (next.token == Tokens.labelVal) {
          t.pop();
          instructions.add(JumpInstruction(mnemonic, labels, info, LabelOrValue.lbl(next.value)));
          labels = [];
          continue;
        } else {
          erroringLines.add(Pair(line, "Jump instruction expected a value or labelVal token, got $next"));
          labels = [];
          t.popToNextLine();
          continue;
        }
      } else if (info.argCount == 0) {
        instructions.add(RetiInstruction(labels, info));
        labels = [];
        continue;
      } else if (info.argCount == 1) {
        Token next = t.peek();
        if (next.isArg) {
          t.pop();
          void fail(String expected, Token got) {
            erroringLines.add(Pair(line, "Invalid token during arg parsing, expected $expected, got $got"));
            labels = [];
            t.popToNextLine();
          }
          Operand? op1 = parseOperandFromStream(next, t, fail);
          if (op1 != null) {
            instructions.add(SingleOperandInstruction(mnemonic, labels, info, op1));
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
        instructions.add(DoubleOperandInstruction(mnemonic, labels, info, op1, op2));
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


void parse(String txt) {
  List<Line> lines = parseLines(txt);

  List<Pair<Line, String>> erroringLines = [];

  lines = parseDefines(lines, erroringLines);

  List<Token> tokens = parseTokens(lines, erroringLines);

  printErrors(erroringLines);
  printTokens(tokens);

  List<Pair<int, String>> errors = [];
  List<Instruction> instructions = parseInstructions(tokens, errors);
  print(errors);
  printInstructions(instructions);
}


void main() {
  var awesome = Awesome();
  print('awesome: ${awesome.isAwesome}');
  print('${Fore.RED}hi');
  print("this should still be red");
  print("and this${Fore.RESET}. but not ${Back.LIGHTBLUE_EX}this${Style.RESET_ALL}");
  print("\n\n");
  //*
  parse("""test:
; this is a comment
test2: add R12 R1; so is this
add @r14+ r4
jmp test2
jmp 0x12
jmp 15
jmp -0x53
""");// */
  /*parse(r"""
MOV #0x4400, SP
.define "R6", Test$Macro_1
AdD #10 [Test$Macro_1] ;comment


; test putchar
mov #0xe2, r15
call #putchar
mov #0x9d, r15
call #putchar
mov #0xa4, r15
call #putchar

mov #0xef, r15
call #putchar
mov #0xb8, r15
call #putchar
mov #0x8f, r15
call #putchar

;mov #0xc17d, r15
mov #0xa1, r15
call #putuc16

mov #0x09a0, r15
call #putuc16

mov #0x42, r15
call #putuc16

MOV #72, r15
MOV #0, r15
mov #0xc17b, r15
mov #0x0003, r15
mov #0x0000, r15
print_loop: ADD.w #1, r15
call #putuc16
jmp print_loop

; a comment
  ; more comments
; test weird upper+lowercase mixtures
loop: CmP #11 0(R10)
MOV #test2, R5
push #0x1234
;JmP -0x8
jmp loop
PUsH.b @R5
; test emulated instructions
DINT
tst.B R10
POP 0(R11)

test_on_a_line:       ; and a comment



jmp test
test: PUSH #14
PUSH #154
test2: PUSH #241
JMP test
JMP test2
MOV #-8, test2(R5)
and.b #-0x1, r5
jmp 0x10 ; this outputs correctly, original would have been jmp 0x10 -> to get from input to correct, use this formula: (original - 2) / 2 --> then convert to signed
SWPB R5
and.b #-0x1, 25(r5)
cmp #0x8, r7


; higher-level utility functions
; <putuc16> - send unicode codepoint (16-bit) to console
putuc16:
; input: r15
; if the codepoint is greater than U+007F, we need two passes, and if it's greater than U+07FF, we need three passes
; handle one-pass case first
; store r13, r14 and r15 on stack
push    r13
push    r14
push    r15
; check if codepoint is greater than U+007F
bit     #0xff80, r15
jc      putuc16_2pass
; if not, we can just send it directly
call    #putchar
; restore r14 and r15 from stack
putuc16_cleanup:
pop     r15
pop     r14
pop     r13
ret
; handle two-pass case
putuc16_2pass:
; check if codepoint is greater than U+07FF
bit     #0xf800, r15
jc      putuc16_3pass
; if not, we need two passes
; done like this: 110xxxxx 10xxxxxx
; put 6 bits in r14
mov     r15, r14
and     #0x3f, r14
; put in 10 header
bis     #0x80, r14
; shift r15 right 6 bits
rra     r15
rra     r15
rra     r15
rra     r15
rra     r15
rra     r15
; set 110 header in r15
and     #0x1f, r15
bis     #0xc0, r15
; send high
push    r14
call    #putchar
pop     r14
; send low
mov     r14, r15
call    #putchar
jmp     putuc16_cleanup
; handle three-pass case
putuc16_3pass:
; done like this: 1110xxxx 10xxxxxx 10xxxxxx
; 1110xxxx in r15 (bits 12-15)
; 10xxxxxx in r14 (bits 6-11)
; 10xxxxxx in r13 (bits 0-5)
mov     r15, r14
mov     r15, r13
; setup r13
and     #0x3f, r13
bis     #0x80, r13
; setup r14
; must shift r14 right 6 bits
rra     r14
rra     r14
rra     r14
rra     r14
rra     r14
rra     r14
and     #0x3f, r14
bis     #0x80, r14
; setup r15
; must shift r15 right 12 bits
rra     r15
rra     r15
rra     r15
rra     r15
rra     r15
rra     r15
rra     r15
rra     r15
rra     r15
rra     r15
rra     r15
rra     r15
and     #0x0f, r15
bis     #0xe0, r15
; send high
push    r14
call    #putchar
pop     r14
; send middle
mov     r14, r15
call    #putchar
; send low
mov     r13, r15
call    #putchar
jmp     putuc16_cleanup

; utility functions
; <INT> - send an interrupt
INT:
mov     0x2(sp), r14
push    sr
mov     r14, r15
swpb    r15
mov     r15, sr
bis     #0x8000, sr ; set highest bit of sr to 1
call    #0x10
pop     sr
ret

; <putchar> - send single character to console
putchar:
decd    sp
push    r15
push    #0x0 ; interrupt type
mov     r15, 0x4(sp)
call    #INT
mov     0x4(sp), r15
add     #0x6, sp
ret

""");*/
}
