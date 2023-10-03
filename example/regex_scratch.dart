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

import 'dart:core';
import 'package:msp430_dart/msp430_dart.dart';

void debugMatch(RegExpMatch? match) {
  if (match == null) {
    print("No match");
  } else {
    print("Named Groups:");
    for (String name in match.groupNames) {
      print("\t$name = ${match.namedGroup(name)}");
    }
    print("Numbered Groups:");
    for (int i = 0; i < match.groupCount; i++) {
      print("\t$i = ${match.group(i)}");
    }
  }
}

void main() {
  //var match = re.define.firstMatch('.define "hello" no');
  var match = re.cString8.firstMatch('.cstr8 test string');
  debugMatch(match);
}