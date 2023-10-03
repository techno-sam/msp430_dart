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

import 'package:msp430_dart/msp430_dart.dart';

void main() {
  Computer c = Computer();
  c.specialInterrupts = false;

  c.setWord(0x0000, 0x3c07); // jmp     0x10
  c.setWord(0x0010, 0x1085); // swpb    R5
  c.setWord(0x0012, 0xf375); // and.b   #-0x1, r5

  c.setWord(0x0014, 0xf3f5); // and.b   #-0x1, 25(r5) ;word 1 (1 extension word)
  c.setWord(0x0016, 0x0019); // and.b   #-0x1, 25(r5) ;word 2 (extension word)

  c.setWord(0x0018, 0x9237); // cmp     #0x8, r7
  c.setWord(0x001a, 0x430f); // mov     #0x0000, r15


  c.step();
  print(c.pc.getWord());
  c.step();
  print(c.pc.getWord());
  c.step();
  print(c.pc.getWord());
  c.step();
  print(c.pc.getWord());
  c.step();
  print(c.pc.getWord());
  c.step();
  print(c.pc.getWord());
}