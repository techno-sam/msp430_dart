import 'dart:typed_data';

import 'package:msp430_dart/msp430_dart.dart';

void main() {
  String stringTests = r"""
mov #0x4400 sp ; setup stack
; string tests

mov #str1 r14
mov #0xfbff r15
call #str_cpy
; end of string tests

; <str_cpy> - string copy
str_cpy:
; @arg r14 src - address of first byte
; @arg r15 dst - address of destination
mov.b @r14 0(r15)
tst.b 0(r14)
jz $end_str_cpy

inc r14
inc r15
jmp str_cpy

$end_str_cpy:
ret

.data

str1:
.cstr8 Hello world

.text
  """;

  Uint8List? assembled = parse(stringTests, silent: false);

  if (assembled == null) {
    throw "Failed to assemble";
  }

  Computer setup() {
    Computer computer = Computer();
    int startAddress = (assembled[0] << 8) + assembled[1];
    for (int i = 2; i < assembled.length; i++) {
      computer.setByte(startAddress + i - 2, assembled[i]);
    }
    computer.pc.setWord(startAddress);
    computer.silent = false;
    return computer;
  }

  Computer computer = setup();
  while (true) {
    computer.step();
  }

  /*int iters = 100000;
  int steps = 500;

  Duration totalTime = const Duration();

  print("Running $iters iterations of $steps steps each");

  for (int i = 0; i < iters; i++) {
    Computer computer = setup();
    DateTime start = DateTime.now();
    for (int s = 0; s < steps; s++) {
      computer.step();
    }
    DateTime end = DateTime.now();
    totalTime += end.difference(start);
  }

  print("$iters iterations of $steps steps each took $totalTime");
  double microsPerCycle = totalTime.inMicroseconds / iters / steps;
  double hz = 1000000 / microsPerCycle;
  double khz = hz / 1000;
  double mhz = khz / 1000;

  print("$microsPerCycle us / cycle ($hz Hz, $khz kHz, $mhz mHz)");*/
}
