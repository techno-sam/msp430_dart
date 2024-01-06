/*
 *     MSP430 emulator and assembler
 *     Copyright (C) 2024  Sam Wagenaar
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

import 'assembler.dart' show emulatedInstructions;
import 'basic_datatypes.dart';

typedef WordStream = ROStack<int>;

abstract class Operand {
  String repr(Map<int, String> labels);
}

String _repr(int value, Map<int, String> labels, [bool signed = false]) {
  if (labels.containsKey(value)) {
    return labels[value]!;
  }
  if (signed) {
    return "0x${value.u16.s16.value.hexString4}";
  } else {
    return "0x${value.hexString4}";
  }
}

class OperandImmediate implements Operand {
  final int value;
  const OperandImmediate(this.value);

  @override
  String repr(Map<int, String> labels) => "#${_repr(value, labels, true)}";
}

class OperandRegisterDirect implements Operand {
  static final List<String> _special = ["pc", "sp", "sr", "cg"];

  final int register;
  const OperandRegisterDirect(this.register);

  @override
  String repr(Map<int, String> labels) => register < _special.length ? _special[register] : "r$register";
}

class OperandIndexed extends OperandRegisterDirect {
  final int offset;
  OperandIndexed(super.register, this.offset);

  @override
  String repr(Map<int, String> labels) => "0x${_repr(offset, labels, true)}(${super.repr})";
}

class OperandAbsolute implements Operand {
  final int address;
  const OperandAbsolute(this.address);

  @override
  String repr(Map<int, String> labels) => "&${_repr(address, labels)}";
}

class OperandSymbolic implements Operand {
  final int address;
  const OperandSymbolic(this.address);

  @override
  String repr(Map<int, String> labels) => _repr(address, labels);
}

class OperandRegisterIndirect extends OperandRegisterDirect {
  OperandRegisterIndirect(super.register);

  @override
  String repr(Map<int, String> labels) => "@${super.repr(labels)}";
}

class OperandRegisterIndirectAutoincrement extends OperandRegisterIndirect {
  OperandRegisterIndirectAutoincrement(super.register);

  @override
  String repr(Map<int, String> labels) => "${super.repr(labels)}+";
}

const List<String> _singleOperandOpcodes = [
  "rrc",
  "swpb",
  "rra",
  "sxt",
  "push",
  "call",
  "reti",
];

const List<String> _doubleOperandOpcodes = [
  "mov",
  "add",
  "addc",
  "subc",
  "sub",
  "cmp",
  "dadd",
  "bit",
  "bic",
  "bis",
  "xor",
  "and",
];

const List<String> _jumpOpcodes = [
  "jne",
  "jeq",
  "jnc",
  "jc",
  "jn",
  "jge",
  "jl",
  "jmp",
];

final List<RegexSubstitution> _cleanupRegex = _makeRegexSubstitutions();

List<RegexSubstitution> _makeRegexSubstitutions() {
  List<RegexSubstitution> cleanupRegex = [];
  for (String emulated in emulatedInstructions.split("\n")) {
    // ADC.x dst	ADDC.x #0,dst
    if (emulated == "") {
      continue;
    }
    emulated = emulated.toLowerCase();
    String target = emulated.split("\t")[0] // ADC.x dst
      .replaceFirst(".x", r"$<bw>")
      .replaceFirst("dst", r"$<dst>")
      .replaceAll("+", r"\+");
    String source = emulated.split("\t")[1] // ADDC.x #0 dst
      .replaceFirst(".x", r"(?<bw>\.b|w)?")
      .replaceFirst("dst", r"(?<dst>.+)")
      .replaceFirst(",", " ")
      .replaceAll("+", r"\+")
      .replaceFirst("#", "#0x000");

    cleanupRegex.add(RegexSubstitution(source, target));
  }
  return cleanupRegex;
}

class Disassembler {
  final WordStream stream;
  final int startAddress;
  late int _currentAddress = startAddress - 2;
  final List<Pair<int, String>> out = [];
  final Map<int, String> labels;
  Disassembler(List<int> data, this.startAddress, this.labels):
        stream = data.readonlyStream;

  void _add(int addr, String contents) {
    for (String line in contents.split("\n")) {
      out.add(Pair(addr, line));
    }
  }

  Iterable<Pair<int, String>> run() {
    while (stream.isNotEmpty) {
      _step();
    }

    return out.map((data) {
      String line = data.second;
      List<String> out = [line];
      for (RegexSubstitution cleanup in _cleanupRegex) {
        String? l = cleanup.apply(line);
        if (l != null) {
          out.add(l);
        }
      }
      out.sort((a, b) => a.length.compareTo(b.length));
      //print(out);
      return Pair(data.first, out[0]);
    });
  }

  int _pop() {
    _currentAddress += 2;
    return stream.pop();
  }

  Operand _getSrc(final int srcReg, final int as, final bool bw) {
    if (srcReg == 3 || (srcReg == 2 && as > 1)) { // CG (or SR outside of Register or Indexed modes)
      int value;
      if (srcReg == 2) {
        if (as == 2) {
          value = 4;
        } else if (as == 3) {
          value = 8;
        } else {
          throw "Invalid addressing mode";
        }
      } else if (srcReg == 3) {
        if (as == 0) {
          value = 0;
        } else if (as == 1) {
          value = 1;
        } else if (as == 2) {
          value = 2;
        } else if (as == 3) {
          value = 0xffff;
        } else {
          throw "Invalid addressing mode";
        }
      } else {
        throw "Unreachable";
      }
      return OperandImmediate(value);
    }

    if (as == 0) { // Register Mode
      return OperandRegisterDirect(srcReg);
    } else if (as == 1) { // Indexed Mode
      if (srcReg == 0) {
        return OperandSymbolic(_currentAddress + _pop());
      } else if (srcReg == 2) {
        return OperandAbsolute(_pop());
      } else {
        return OperandIndexed(srcReg, _pop());
      }
    } else if (as == 2) { // Register Indirect Mode
      return OperandRegisterIndirect(srcReg);
    } else if (as == 3) { // Register Indirect Autoincrement Mode
      if (srcReg == 0) {
        return OperandImmediate(_pop());
      }
      return OperandRegisterIndirectAutoincrement(srcReg);
    } else {
      throw "Invalid addressing mode";
    }
  }

  Operand _getDst(final int dstReg, final int ad, final bool bw) {
    if (ad == 0) { // Register Mode
      return OperandRegisterDirect(dstReg);
    } else if (ad == 1) { // Indexed Mode
      if (dstReg == 0) {
        return OperandSymbolic(_currentAddress + _pop());
      } else if (dstReg == 2) {
        return OperandAbsolute(_pop());
      } else {
        return OperandIndexed(dstReg, _pop());
      }
    } else {
      throw "Invalid addressing mode";
    }
  }

  void _step() {
    final int instr = _pop();
    if (instr >> 10 == 4) { // 0b000100
      _processSingleOperand(instr);
    } else if (instr >> 13 == 1) { // 0b001
      _processJump(instr);
    } else if (instr != 0) {
      _processDoubleOperand(instr);
    }

    //out.add("${(_currentAddress).toRadixString(16).padLeft(4, "0")}: ${instr.toRadixString(16).padLeft(4, "0")}");
  }

  String _labelPrefix() {
    if (labels.containsKey(_currentAddress)) {
      String lbl = labels[_currentAddress]!;
      return "${lbl.startsWith(r'$') ? '' : '\n'}$lbl:\n";
    }
    return "";
  }

  void _processSingleOperand(int instr) {
    final int addr = _currentAddress;
    final lbl = _labelPrefix();
    final opcode = (instr >> 7) & 0x7;
    final srcReg = instr & 0xf;
    final as = (instr >> 4) & 0x3;
    final bw = (instr >> 6) & 0x1 == 1;

    final src = _getSrc(srcReg, as, bw);
    final opc = _singleOperandOpcodes[opcode];
    _add(addr, "$lbl$opc${bw ? '.b' : ''} ${src.repr(labels)}");
  }

  void _processJump(int instr) {
    final int addr = _currentAddress;
    final lbl = _labelPrefix();
    int offset = instr & 0x3ff;
    if (offset > 512) {
      offset -= 1024;
    }

    final condition = (instr >> 10) & 0x7;
    final con = _jumpOpcodes[condition];

    int targetOffset = (offset * 2) + 2;
    int targetAddress = _currentAddress + targetOffset;
    String target;
    if (labels.containsKey(targetAddress)) {
      target = labels[targetAddress]!;
    } else {
      target = "$targetOffset";
    }
    _add(addr, "$lbl$con $target");
  }

  void _processDoubleOperand(int instr) {
    final int addr = _currentAddress;
    final lbl = _labelPrefix();
    final opcode = (instr >> 12) & 0xf;
    final srcReg = (instr >> 8) & 0xf;
    final ad = (instr >> 7) & 0x1;
    final bw = (instr >> 6) & 0x1 == 1;
    final as = (instr >> 4) & 0x3;
    final dstReg = instr & 0xf;

    if (opcode < 4) {
      return;
    }

    final src = _getSrc(srcReg, as, bw);
    final dst = _getDst(dstReg, ad, bw);

    final opc = _doubleOperandOpcodes[opcode - 4];

    _add(addr, "$lbl$opc${bw ? '.b' : ''} ${src.repr(labels)} ${dst.repr(labels)}");
  }
}

void testDisassembler() {
  final Disassembler dis = Disassembler([
    0x4125,
    0x4036, 0x002b,
    0x4035, 0x0036,
    0x12b0, 0x4414,
    0x1290, 0x0006,
    0x3c00,

    0x4a0b,
    0x4130,

    0xd222
  ], 0x4400, {
    0x4414: "test"
  });
  final out = dis.run();
  print(out
      //.map((e) => e.second)
      .map((e) => "0x${e.first.hexString4}\t${e.second}")
      .join("\n"));
}