import 'dart:convert';
import 'dart:io' show stdin;
import 'dart:typed_data';
import 'package:msp430_dart/msp430_dart.dart' as msp430;

void main(List<String> arguments) async {
  final input = String.fromCharCodes(await stdin.first);
  Uint8List? parsed = msp430.parse(input, silent: true);
  if (parsed == null) {
    print("<FAILURE>");
  } else {
    if (arguments.contains("--debug")) {
      for (var i = 0; i < parsed.length; i++) {
        print("${i.toRadixString(16).padLeft(4, '0')}: 0x${parsed[i].toRadixString(16).padLeft(2, '0')}");
      }
    }
    print(base64Encode(parsed));
  }
}
