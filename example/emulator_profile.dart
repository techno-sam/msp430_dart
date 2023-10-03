/*
 *     MSP430 emulator and assembler
 *     Copyright (C) 2023  Sam Wagenaar
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
 *
 */

import 'dart:typed_data';

import 'package:msp430_dart/msp430_dart.dart';

void main() {
  String fibonacci = """
.define "r5" A
.define "r6" B
.define "r15" OUT
mov #0 [A]
mov #1 [B]
mov #0x4400 sp

loop:
add [A] [B] ; add value of A into B
mov [B] [OUT] ; copy value of B into OUT
add [B] [A] ; add value of B into A
mov [A] [OUT] ; copy value of A into OUT
jmp loop
  """;

  Uint8List? assembled = parse(fibonacci, silent: true);

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
    computer.silent = true;
    return computer;
  }

  int iters = 100000;
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

  print("$microsPerCycle us / cycle ($hz Hz, $khz kHz, $mhz mHz)");
}
