/*
 *     MSP430 emulator and assembler
 *     Copyright (C) 2023-2023  Sam Wagenaar
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

import 'dart:core';


class Regex {
  RegExp define = RegExp("\\.define \"(.*)\",? *([A-z\$_][A-z0-9\$_]*)");
  RegExp label = RegExp("^([A-z\$_][A-z0-9\$_]*)\$");
  RegExp whitespaceSplit = RegExp(r"([^\s,]*)(?:[\s,]*)");
  // DONE registers need to be able to handle labels
  RegExp regIdx = RegExp(r"^(?<sign>[-+])?(?:(?:0x(?<hex>[0-9a-fA-F]{1,4}))|(?<digits>\d+))[(](?<reg>pc|sp|sr|cg|(?:r[0-9])|(?:r1[0-5]))[)]$");
  RegExp regIndirect = RegExp(r"^@(?<reg>pc|sp|sr|cg|(?:r[0-9])|(?:r1[0-5]))(?<autoincrement>\+?)$");
  RegExp regImmediate = RegExp(r"^#(?<sign>[-+])?(?:(?:0[xX](?<hex>[0-9a-fA-F]{1,4}))|(?<digits>\d+))$");
  RegExp regAbsolute = RegExp(r"^&(?:(?:0[xX](?<hex>[0-9a-fA-F]{1,4}))|(?<digits>\d+))$");
  RegExp unsignedNumber = RegExp(r"^(?:(?:0[xX](?<hex>[0-9a-fA-F]{1,4}))|(?<digits>\d+))$");

  // labeled registers
  RegExp regIdxLbl = RegExp(r"^(?<label>[A-z$_][A-z0-9$_]*)[(](?<reg>pc|sp|sr|cg|(?:r[0-9])|(?:r1[0-5]))[)]$", caseSensitive: false);
  RegExp regAbsoluteLbl = RegExp(r"^&(?<label>[A-z$_][A-z0-9$_]*)$", caseSensitive: false);
  RegExp regImmediateLbl = RegExp(r"^#(?<label>[A-z$_][A-z0-9$_]*)$", caseSensitive: false);

  // jump instructions
  RegExp jmpNumeric = RegExp(r"^(?<sign>[-+])?(?:(?:0x(?<hex>[0-9a-fA-F]{1,4}))|(?<digits>\d+))$");

  // data
  RegExp dataMode = RegExp(r"^\.data$");
  RegExp textMode = RegExp(r"^\.text$");

  RegExp cString8 = RegExp(r'^.cstr8 (?<string>.*)$');

  // special
  RegExp interrupt = RegExp(r"^\.interrupt (?:(?:0[xX](?<vector_hex>[0-9a-fA-F]{1,4}))|(?<vector_digits>\d+)) (?<target_label>[A-z$_][A-z0-9$_]*)$");
  RegExp localBlock = RegExp(r"^\.locblk$");
}