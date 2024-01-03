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

import 'dart:convert';
import 'dart:io' show stdin;
import 'dart:typed_data';
import 'package:msp430_dart/msp430_dart.dart' as msp430;
import 'package:msp430_dart/src/assembler.dart';

void main(List<String> arguments) async {
  final input = String.fromCharCodes(await stdin.first);
  msp430.MutableObject<ListingGenerator>? lister;
  if (arguments.contains("--list")) {
    lister = msp430.MutableObject();
  }
  Uint8List? parsed = msp430.parse(input, silent: true, listingGen: lister);
  if (parsed == null) {
    print("<FAILURE>");
  } else {
    if (arguments.contains("--debug")) {
      for (var i = 0; i < parsed.length; i++) {
        print("${i.toRadixString(16).padLeft(4, '0')}: 0x${parsed[i].toRadixString(16).padLeft(2, '0')}");
      }
    }
    ListingGenerator? gen = lister?.get();
    if (gen != null) {
      print("Listing:");
      print(gen.output());
    }
    print(base64Encode(parsed));
  }
}
