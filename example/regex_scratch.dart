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