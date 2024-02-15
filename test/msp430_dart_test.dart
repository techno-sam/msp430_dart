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

import 'dart:isolate';
import 'dart:typed_data';

import 'package:msp430_dart/msp430_dart.dart';
import 'package:msp430_dart/src/assembler.dart';
import 'package:test/test.dart';

Future<void> Function() _wrapAsAsync(void Function() target) {
  return () async {
    await Isolate.run(target);
  };
}

Uint8List _parseErrorless(String code, [String? context]) {
  return parse(code, silent: false, errorConsumer: (errors) {
    for (final entry in errors.entries) {
      print("\t${Fore.RED}${entry.key}:\t${entry.value}${Fore.RESET}");
    }
    if (errors.isNotEmpty) throw "${context == null ? "" : "($context) "}assembly error";
  })!;
}

void main() {
  test("basic assembly", () {
    parse("mov #0x4400 sp\nreti", silent: true, errorConsumer: (errors) {
      if (errors.isNotEmpty) throw "assembly error";
    });
  });
  test("macro expansion", () {
    final code1 = """
    push @r7
    .macro test_macro(a, beta, t3st)
    mov {a} r6
    add {beta} 0({t3st})
    mov @{t3st} {a}
    .endmacro
    inc r8
    test_macro(r5, #0x4201, r7)
    sub r9 r10
    """;
    final code2 = """
    push @r7
    inc r8
    
    mov r5 r6
    add #0x4201 0(r7)
    mov @r7 r5
    
    sub r9 r10
    """;
    final asm1 = _parseErrorless(code1, "code1");
    final asm2 = _parseErrorless(code2, "code2");
    assert(asm1.equals(asm2));
  });
  test("nested macro expansion", () {
    final code1 = """
    push @r7
    .macro nested(ti, msp)
      mov {ti} {msp}
    .endmacro
    
    .macro test_macro(a, beta, t3st)
      nested({a}, r6) ; mov {a} r6
      add {beta} 0({t3st})
      mov @{t3st} {a}
    .endmacro
    inc r8
    test_macro(r5, #0x4201, r7)
    sub r9 r10
    """;
    final code2 = """
    push @r7
    inc r8
    
    mov r5 r6
    add #0x4201 0(r7)
    mov @r7 r5
    
    sub r9 r10
    """;
    final asm1 = _parseErrorless(code1, "code1");
    final asm2 = _parseErrorless(code2, "code2");
    assert(asm1.equals(asm2));
  });
  test("bounded nested macro expansion", _wrapAsAsync(() {
    final code = """
    .macro test(a, b)
      add {a} {b}
      test(b, a)
    .endmacro
    test(r5, r6)
    """;

    try {
      executeWithPanicOnRecursionLimit(() => _parseErrorless(code));
    } on MacroRecursionError {
      return;
    }
    fail("Expected a recursion error");
  }),
  timeout: const Timeout(Duration(seconds: 1)));
}
