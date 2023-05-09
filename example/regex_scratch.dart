import 'dart:core';
import 'package:msp430_dart/msp430_dart.dart';

void main() {
  var match = re.define.firstMatch('.define "hello" no');
  print(match?.groups([1, 2]));
}