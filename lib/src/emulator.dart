import 'package:msp430_dart/msp430_dart.dart';
import 'package:binary/binary.dart';

class ExecutionError extends ArgumentError {
  ExecutionError(dynamic message) : super(message);
}

class Register {
  final int number; // this is the id
  Uint8 _high = Uint8.zero;
  Uint8 _low = Uint8.zero;
  Register(this.number);

  void runAssertions() {}

  Uint8Couple get() => Uint8Couple(_high, _low);
  void set(Uint8Couple couple) {
    _high = couple.high;
    _low = couple.low;
    runAssertions();
  }

  int getWordInt() {
    return (_high.value >> 8) + _low.value;
  }

  Uint16 getWord() {
    return getWordInt().u16;
  }

  int getByteInt() {
    return _low.value;
  }

  Uint8 getByte() {
    return getByteInt().u8;
  }

  void setWord(int value, [bool signed = false]) {
    if (value != overflowU16(value)) {
      throw ExecutionError("Overflow value");
    }
    if (value < 0) {
      if (signed && value < 0) {
        value = (value + 1).abs() ^ 0xffff;
      } else {
        throw ExecutionError("Attempting to set a negative value using unsigned mode");
      }
    }

    set(Uint8Couple.fromU16(value.u16));
  }
  
  void setByte(int value, [bool signed = false]) {
    if (value != overflowU8(value)) {
      throw ExecutionError("Overflow value");
    }
    if (value < 0) {
      if (signed) {
        value = (value + 1).abs() ^ 0xff;
      } else {
        throw ExecutionError("Attempting to set a negative value using unsigned mode");
      }
    }
    _high = Uint8.zero;
    _low = value.u8;
    runAssertions();
  }

  Uint8Couple get contents => get();
  set contents(Uint8Couple contents) => set(contents);
}

class ProgramCounterRegister extends Register {
  ProgramCounterRegister() : super(0);

  @override
  void runAssertions() {
    if (getWordInt() % 2 != 0) {
      throw ExecutionError("Program counter must be word-aligned");
    }
  }
}

class StackPointerRegister extends Register {
  StackPointerRegister() : super(1);

  @override
  void runAssertions() {
    if (getWordInt() % 2 != 0) {
      throw ExecutionError("Stack pointer must be word-aligned");
    }
  }

  @override
  void setWord(int value, [bool signed = false]) {
    try {
      super.setWord(value, signed);
    } on ExecutionError {
      throw ExecutionError("Stack overflow");
    }
  }

  @override
  void setByte(int value, [bool signed = false]) {
    try {
      super.setByte(value, signed);
    } on ExecutionError {
      throw ExecutionError("Stack overflow");
    }
  }
}

class StatusRegister extends Register {
  StatusRegister() : super(2);

  @override
  int getByteInt() {
    throw ExecutionError("Cannot read SR (R2) in byte mode");
  }

  @override
  void setByte(int value, [bool signed = false]) {
    throw ExecutionError("Cannot write SR (R2) in byte mode");
  }

  bool _getBit(int msp430DocIdx) {
    if (msp430DocIdx < 0 || msp430DocIdx > 15) {
      throw ExecutionError("Invalid SR bit index");
    }
    return (getWordInt() >> msp430DocIdx) & 1 == 1;
  }

  void _setBit(int msp430DocIdx, bool value) {
    if (msp430DocIdx < 0 || msp430DocIdx > 15) {
      throw ExecutionError("Invalid SR bit index");
    }
    int curr = getWordInt();
    if (value) {
      curr |= 1 << msp430DocIdx;
    } else {
      curr &= ~(1 << msp430DocIdx);
    }
    setWord(curr);
  }

  bool get overflow => _getBit(8);
  set overflow(bool value) => _setBit(8, value);
  void clrOverflow() => overflow = false;
  bool get v => overflow;
  set v(bool value) => overflow = value;

  bool get cpuOff => _getBit(4);
  set cpuOff(bool value) => _setBit(4, value);
  void clrCpuOff() => cpuOff = false;

  bool get negative => _getBit(2);
  set negative(bool value) => _setBit(2, value);
  void clrNegative() => negative = false;
  bool get n => negative;
  set n(bool value) => negative = value;

  bool get zero => _getBit(1);
  set zero(bool value) => _setBit(1, value);
  void clrZero() => zero = false;
  bool get z => zero;
  set z(bool value) => zero = value;

  bool get carry => _getBit(0);
  set carry(bool value) => _setBit(0, value);
  void clrCarry() => carry = false;
  bool get c => carry;
  set c(bool value) => carry = value;

  bool getFlag(String flag) {
    flag = flag.toLowerCase();
    switch (flag) {
      case "v":
      case "overflow":
        return overflow;
      case "cpuoff":
        return cpuOff;
      case "n":
      case "negative":
        return negative;
      case "z":
      case "zero":
        return zero;
      case "c":
      case "carry":
        return carry;
      default:
        throw ExecutionError("Invalid flag name");
    }
  }
}

class ConstantGeneratorRegister extends Register {
  ConstantGeneratorRegister() : super(3);

  @override
  Uint8Couple get() => Uint8Couple.zero;

  @override
  Uint16 getWord() => Uint16.zero;

  @override
  int getWordInt() => 0;

  @override
  Uint8 getByte() => Uint8.zero;

  @override
  int getByteInt() => 0;
}

class MemoryMap {
  late List<int> _memory; // list of bytes

  MemoryMap(int size) {
    _memory = List<int>.filled(size, 0);
  }

  int get length => _memory.length;
  bool get isEmpty => _memory.isEmpty;
  bool get isNotEmpty => _memory.isNotEmpty;

  int getWord(int index) {
    if (index < 0 || index + 1 >= _memory.length) {
      throw ExecutionError("Memory access out of bounds");
    }
    if (index % 2 != 0) {
      throw ExecutionError("Memory access must be word-aligned");
    }
    return (_memory[index] << 8) + _memory[index + 1];
  }

  void setWord(int index, int value) {
    if (index < 0 || index + 1 >= _memory.length) {
      throw ExecutionError("Memory access out of bounds");
    }
    if (index % 2 != 0) {
      throw ExecutionError("Memory access must be word-aligned");
    }
    _memory[index] = (value >> 8) & 0xff;
    _memory[index + 1] = value & 0xff;
  }

  int getByte(int index) {
    if (index < 0 || index + 1 >= _memory.length) {
      throw ExecutionError("Memory access out of bounds");
    }
    return _memory[index];
  }

  void setByte(int index, int value) {
    if (index < 0 || index + 1 >= _memory.length) {
      throw ExecutionError("Memory access out of bounds");
    }
    _memory[index] = overflowU8(value);
  }
}

abstract class WriteTarget {
  void setByte(int value, [bool signed = false]);
  void setWord(int value, [bool signed = false]);
}

class VoidWriteTarget extends WriteTarget {
  @override
  void setByte(int value, [bool signed = false]) {}

  @override
  void setWord(int value, [bool signed = false]) {}
}

class RegisterWriteTarget extends WriteTarget {
  final Register register;
  RegisterWriteTarget(this.register);

  @override
  void setByte(int value, [bool signed = false]) {
    register.setByte(value, signed);
  }

  @override
  void setWord(int value, [bool signed = false]) {
    register.setWord(value, signed);
  }

  @override
  String toString() {
    String extra = {
      0: " (PC)",
      1: " (SP)",
      2: " (SR)",
      3: " (CG)",
    }[register.number] ?? "";
    return "<RegisterWriteTarget register=R${register.number}$extra>";
  }
}

class MemoryWriteTarget extends WriteTarget {
  final int address;
  final Computer computer;
  MemoryWriteTarget(this.address, this.computer);

  @override
  void setByte(int value, [bool signed = false]) {
    computer.setByte(address, value, signed);
  }

  @override
  void setWord(int value, [bool signed = false]) {
    computer.setWord(address, value, signed);
  }

  @override
  String toString() => "<MemoryWriteTarget address=0x${address.toRadixString(16).padLeft(4, '0')}>";
}

enum SingleOperandOpcodes {
  rrc,
  swpb,
  rra,
  sxt,
  push,
  call,
  reti
}

enum DoubleOperandOpcodes {
  mov,
  add,
  addc,
  subc,
  sub,
  cmp,
  dadd,
  bit,
  bic,
  bis,
  xor,
  and
}

class Computer {
  List<Register> registers = [];
  MemoryMap memory = MemoryMap(0x10000); // 64KB of memory (addresses 0x0000 to 0xffff)

  bool silent = false;
  String Function() inputFunction = () => throw ExecutionError("No input function defined");
  Function(String) outputFunction = (String s) => throw ExecutionError("No output function defined");

  List<int> _outputBuffer = [];
  bool specialInterrupts = true;

  Computer() {
    registers.add(ProgramCounterRegister());
    registers.add(StackPointerRegister());
    registers.add(StatusRegister());
    registers.add(ConstantGeneratorRegister());
    for (int i = 4; i < 16; i++) {
      registers.add(Register(i));
    }
  }

  ProgramCounterRegister get pc => registers[0] as ProgramCounterRegister;
  StackPointerRegister get sp => registers[1] as StackPointerRegister;
  StatusRegister get sr => registers[2] as StatusRegister;
  ConstantGeneratorRegister get cg => registers[3] as ConstantGeneratorRegister;

  void reset() {
    registers.forEach((Register r) => r.setWord(0));
    memory = MemoryMap(0x10000);
    _outputBuffer = [];
  }

  int getByte(int address, [bool signed = false]) {
    int val = memory.getByte(address);
    if (signed) {
      val = val.u8.s8.value; // value as u8 --> convert to s8 --> back to int
    }
    return val;
  }

  int getWord(int address, [bool signed = false]) {
    int val = memory.getWord(address);
    if (signed) {
      val = val.u16.s16.value; // value as u16 --> convert to s16 --> back to int
    }
    return val;
  }

  void setByte(int address, int value, [bool signed = false]) {
    if (signed) {
      value = value.s8.u8.value; // value as s8 --> convert to u8 --> back to int
    }
    memory.setByte(address, value);
  }

  void setWord(int address, int value, [bool signed = false]) {
    if (signed) {
      value = value.s16.u16.value; // value as s16 --> convert to u16 --> back to int
    }
    memory.setWord(address, value);
  }

  void _print(String msg) {
    if (!silent) {
      print(msg);
    }
  }

  void printStatus() {
    var space = " | ";
    var line1 = "";
    var line2 = "";
    var named = {
      0: "pc",
      1: "sp",
      2: "sr",
      3: "cg",
    };
    for (int i = 0; i < 16; i++) {
      if (3 < i && i < 10) {
        line1 += "0";
      }
      if (named.containsKey(i)) {
        line1 += named[i]!;
        line1 += "_$i";
      } else {
        line1 += "$i  ";
      }
      line1 += space;
      line2 += registers[i].getWordInt().toRadixString(16).padLeft(4, '0') + space;
    }
    line1 += "FLAG";
    for (var name in ["N", "Z", "C", "V"]) {
      if (sr.getFlag(name)) {
        line2 += name;
      } else {
        line2 += "_";
      }
    }
    _print("\n\nStatus:");
    _print(line1);
    _print(line2);
    _print("\n\n");
  }

  void step() {
    if (pc.getWordInt() == 0x10 && specialInterrupts) {
      _print("Special case software interrupt");

      int interruptKind = sr.getWordInt() >> 8 & 0x7f; // (0b0111_1111) only uses 7 bits for interrupts (max 127)

      if (true) {
        throw ExecutionError("Not implemented yet");
      }

      pc.setWord(pc.getWordInt() + 2);
      _execute(0x4130); // ret
    } else {
      int instruction = getWord(pc.getWordInt());
      pc.setWord(pc.getWordInt() + 2);
      _execute(instruction);
      printStatus();
    }
  }

  void _execute(int instruction) {
    /*
    Execute a single TI MSP430 instruction.
    Decode opcode, execute operation
    start by deciding if it's a jump instruction, single operand instruction, or double operand instruction
    if the opcode starts with 000100 it is a single operand instruction
    if the opcode starts with 001 it is a jump instruction
    otherwise it is a double operand instruction
    check biggest 3 bits for jump, then check biggest 6 bits for single operand, otherwise double operand
     */
    instruction &= 0xffff;
    if (instruction >> 13 == 1) { // 0b001
      _print("It's a jump instruction");
      _executeJump(instruction);
    } else if (instruction >> 10 == 4) { // 0b000100
      _print("It's a single operand instruction");
      _executeSingleOperand(instruction);
    } else {
      _print("It's a double operand instruction");
      _executeDoubleOperand(instruction);
    }
  }

  void _executeJump(int instruction) {
    _print("Jump instruction: ${instruction.toRadixString(16)}");
    // decode target (lowest 10 bits)
    int offset = instruction & 0x3ff;
    if (offset > 512) {
      offset -= 1024;
    }
    int condition = (instruction >> 10) & 0x7;

    if (condition == 0) { // JNE/JNZ
      _print("JNE/JNZ");
      if (sr.z) {
        return;
      }
    } else if (condition == 1) { // JEQ/JZ
      _print("JEQ/JZ");
      if (!sr.z) {
        return;
      }
    } else if (condition == 2) { // JNC/JLO
      _print("JNC/JLO");
      if (sr.c) {
        return;
      }
    } else if (condition == 3) { // JC/JHS
      _print("JC/JHS");
      if (!sr.c) {
        return;
      }
    } else if (condition == 4) { // JN
      _print("JN");
      if (!sr.n) {
        return;
      }
    } else if (condition == 5) { // JGE
      _print("JGE");
      if (sr.n ^ sr.v) {
        return;
      }
    } else if (condition == 6) { // JL
      _print("JL");
      if (!(sr.n ^ sr.v)) {
        return;
      }
    } else if (condition == 7) { // JMP
      _print("JMP");
    } else {
      throw ExecutionError("Invalid jump instruction");
    }
    pc.setWord(pc.getWordInt() + offset * 2);
  }

  Pair<int, WriteTarget> _getSrc(int srcReg, int as, bool bw) {
    if (srcReg == 3 || (srcReg == 2 && as != 0)) { // CG or (SR outside of Register mode)
      int src = 0;
      if (srcReg == 2) {
        if (as == 1) {
          src = 0;
        } else if (as == 2) {
          src = 4;
        } else if (as == 3) {
          src = 8;
        }
      } else if (srcReg == 3) {
        if (as == 0) {
          src = 0;
        } else if (as == 1) {
          src = 1;
        } else if (as == 2) {
          src = 2;
        } else if (as == 3) {
          src = bw ? 0xff : 0xffff;
        }
      }

      return Pair(src, VoidWriteTarget());
    }

    int src;
    WriteTarget wt;
    if (as == 0) {
      if (bw) {
        src = registers[srcReg].getByteInt();
      } else {
        src = registers[srcReg].getWordInt();
      }
      wt = RegisterWriteTarget(registers[srcReg]);
    } else if (as == 1) {
      int offset = getWord(pc.getWordInt()) + registers[srcReg].getWordInt();
      offset &= 0xffff;
      pc.setWord(pc.getWordInt() + 2);
      if (bw) {
        src = getByte(offset);
      } else {
        src = getWord(offset);
      }
      wt = MemoryWriteTarget(offset, this);
    } else if (as == 2) {
      int target = registers[srcReg].getWordInt();
      if (bw) {
        src = getByte(target);
      } else {
        src = getWord(target);
      }
      wt = MemoryWriteTarget(target, this);
    } else if (as == 3) {
      int memTarget = registers[srcReg].getWordInt();
      if (bw) {
        src = getByte(memTarget);
        int extra = (registers[srcReg] == pc || registers[srcReg] == sp) ? 1 : 0;
        registers[srcReg].setWord(memTarget + 1 + extra);
      } else {
        src = getWord(memTarget);
        registers[srcReg].setWord(memTarget + 2);
      }
      wt = MemoryWriteTarget(memTarget, this);
    } else {
      throw ExecutionError("Invalid source addressing mode");
    }
    return Pair(src, wt);
  }

  void _executeSingleOperand(int instruction) { // PUSH implementation: decrement SP, then execute as usual
    _print("Single operand instruction ${instruction.toRadixString(16)}");
    int opcode = (instruction >> 7) & 0x7; // 3-bit (0b111)
    int srcReg = instruction & 0xf; // 4-bit (0b1111)
    int as = (instruction >> 4) & 0x3; // 2-bit (0b11)
    bool bw = (instruction >> 6) & 0x1 == 1;

    // read source
    Pair<int, WriteTarget> srcWt = _getSrc(srcReg, as, bw);
    int src = srcWt.first;
    WriteTarget wt = srcWt.second;
    _print("src: $src");

    bool noWrite = false;

    // apply operation
    SingleOperandOpcodes opc = SingleOperandOpcodes.values[opcode];
    _print(opc.name);
    
    switch(opc) {
      case SingleOperandOpcodes.rrc:
        bool carry = src & 1 == 1;
        src >>= 1;
        //put carry back in, taking into account byte-mode as bw
        if (bw) {
          src |= (sr.carry.int << 7);
        } else {
          src |= (sr.carry.int << 15);
        }
        sr.carry = carry;
        sr.n = (src >> (bw ? 7 : 15) & 1) == 1;
        sr.z = src == 0;
        sr.v = false;
        break;
      case SingleOperandOpcodes.swpb:
        if (bw) {
          throw ExecutionError("SWPB cannot be used in byte mode");
        }
        src = ((src & 0xff00) >> 8) | ((src & 0xff) << 8);
        break;
      case SingleOperandOpcodes.rra:
        sr.c = src & 1 == 1;
        int msbToOr = src & (bw ? 128 : 32768);
        src >>= 1;
        src |= msbToOr;
        sr.n = (src >> (bw ? 7 : 15) & 1) == 1;
        sr.n = src == 0;
        sr.v = false;
        break;
      case SingleOperandOpcodes.sxt:
        if (bw) {
          throw ExecutionError("SXT cannot be used in byte mode");
        }
        src &= 0xff;
        if ((src >> 7 & 1) == 1) {
          src |= 0xff00;
          sr.n = true;
        } else {
          sr.n = false;
        }
        sr.z = src == 0;
        sr.c = src != 0;
        sr.v = false;
        break;
      case SingleOperandOpcodes.push:
        sp.setWord(sp.getWordInt() - 2);
        if (wt is RegisterWriteTarget && wt.register == pc) {
          if (bw) {
            src = pc.getByteInt();
          } else {
            src = pc.getWordInt();
          }
        }
        noWrite = true;
        if (bw) {
          setByte(sp.getWordInt(), src);
        } else {
          setWord(sp.getWordInt(), src);
        }
        break;
      case SingleOperandOpcodes.call:
        if (bw) {
          throw ExecutionError("CALL cannot be used in byte mode");
        }
        sp.setWord(sp.getWordInt() - 2);
        setWord(sp.getWordInt(), pc.getWordInt());
        pc.setWord(src);
        noWrite = true;
        break;
      case SingleOperandOpcodes.reti:
        throw UnimplementedError("RETI not implemented because interrupts don't exist");
        break;
    }
    if (!noWrite) {
      if (bw) {
        wt.setByte(src);
      } else {
        wt.setWord(src);
      }
    }
  }

  void _setFlags(int src, int prevDst, int fullDst, int dst, bool byteMode) {
    sr.zero = dst == 0;
    sr.negative = (dst >> (byteMode ? 7 : 15) & 1) == 1;
    sr.carry = fullDst > (byteMode ? 0xff : 0xffff);
    // overflow is set if the sign of the operands is the same, and the sign of the result is different (e.g. positive + positive = negative, or negative + negative = positive)
    sr.overflow = ((prevDst >> (byteMode ? 7 : 15) & 1) == (src >> (byteMode ? 7 : 15) & 1))
        && ((prevDst >> (byteMode ? 7 : 15) & 1) != (dst >> (byteMode ? 7 : 15) & 1));
  }

  void _executeDoubleOperand(int instruction) { // MOV order: read value, increment if needed, set value
    _print("Double operand instruction ${instruction.toRadixString(16)}");
    int opcode = (instruction >> 12) & 0xf; // 4-bit (0b1111)
    int srcReg = (instruction >> 8) & 0xf; // 4-bit (0b1111)
    int ad = (instruction >> 7) & 0x1; // 1-bit (0b1)
    bool bw = (instruction >> 6) & 0x1 == 1; // 1-bit (0b1)
    int as = (instruction >> 4) & 0x3; // 2-bit (0b11)
    int dstReg = instruction & 0xf; // 4-bit (0b1111)

    // read source
    int src = _getSrc(srcReg, as, bw).first;

    int dst;
    WriteTarget wt;
    // read value of dst and make a write target
    if (ad == 0) {
      if (bw) {
        dst = registers[dstReg].getByteInt();
      } else {
        dst = registers[dstReg].getWordInt();
      }
      wt = RegisterWriteTarget(registers[dstReg]);
    } else {
      int offset = getWord(pc.getWordInt()) + registers[dstReg].getWordInt();
      offset &= 0xffff;
      pc.setWord(pc.getWordInt() + 2);
      if (bw) {
        dst = getByte(offset);
      } else {
        dst = getWord(offset);
      }
      wt = MemoryWriteTarget(offset, this);
    }
    _print("dst: $dst, wt: $wt");

    bool noWrite = false;

    DoubleOperandOpcodes opc = DoubleOperandOpcodes.values[opcode - 4];

    _print(opc.name);
    switch (opc) {
      case DoubleOperandOpcodes.mov:
        dst = src;
        break;
      case DoubleOperandOpcodes.add:
        int prevDst = dst;
        dst += src;
        int dstFull = dst;
        dst &= bw ? 0xff : 0xffff;
        _setFlags(src, prevDst, dstFull, dst, bw);
        break;
      case DoubleOperandOpcodes.addc:
        int prevDst = dst;
        dst += src + (sr.carry.int);
        int dstFull = dst;
        dst &= bw ? 0xff : 0xffff;
        _setFlags(src, prevDst, dstFull, dst, bw);
        break;
      case DoubleOperandOpcodes.subc:
        int prevDst = dst;
        dst = dst - src - 1 + sr.carry.int;
        int dstFull = dst;
        dst &= bw ? 0xff : 0xffff;
        _setFlags(src, prevDst, dstFull, dst, bw);
        break;
      case DoubleOperandOpcodes.sub:
        int prevDst = dst;
        dst = dst - src;
        int dstFull = dst;
        dst &= bw ? 0xff : 0xffff;
        _setFlags(src, prevDst, dstFull, dst, bw);
        break;
      case DoubleOperandOpcodes.cmp:
        int prevDst = dst;
        int fakeDst = dst - src;
        int dstFull = fakeDst;
        fakeDst &= bw ? 0xff : 0xffff;
        _setFlags(src, prevDst, dstFull, fakeDst, bw);
        noWrite = true;
        break;
      case DoubleOperandOpcodes.dadd:
        throw UnimplementedError("DADD - not sure how this works, can't implement");
        break;
      case DoubleOperandOpcodes.bit:
        int prevDst = dst;
        int fakeDst = dst & src;
        int dstFull = fakeDst;
        fakeDst &= bw ? 0xff : 0xffff;
        _setFlags(src, prevDst, dstFull, fakeDst, bw);
        sr.c = !sr.zero;
        sr.v = false;
        noWrite = true;
        break;
      case DoubleOperandOpcodes.bic:
        dst &= ~src;
        break;
      case DoubleOperandOpcodes.bis:
        dst |= src;
        break;
      case DoubleOperandOpcodes.xor:
        int prevDst = dst;
        dst ^= src;
        sr.n = (dst >> (bw ? 7 : 15) & 1) == 1;
        sr.z = dst == 0;
        sr.c = dst != 0;
        sr.v = (src >> (bw ? 7 : 15) & 1) == 1 && (prevDst >> (bw ? 7 : 15) & 1) == 1;
        break;
      case DoubleOperandOpcodes.and:
        dst &= src;
        sr.n = (dst >> (bw ? 7 : 15) & 1) == 1;
        sr.z = dst == 0;
        sr.c = dst != 0;
        sr.v = false;
        break;
    }

    if (!noWrite) {
      if (bw) {
        wt.setByte(dst);
      } else {
        wt.setWord(dst);
      }
    }
  }
}