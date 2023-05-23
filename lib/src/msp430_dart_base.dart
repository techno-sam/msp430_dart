// TODO: Put public facing types in this file.
import 'dart:core' as core;
import 'dart:core';
import 'package:binary/binary.dart';

/// Checks if you are awesome. Spoiler: you are.
class Awesome {
  bool get isAwesome => true;
}

class Pair<A, B> {
  final A first;
  final B second;
  const Pair(this.first, this.second);

  @override
  String toString() {
    return 'Pair<$A, $B>[$first, $second]';
  }
}

class Couple<T> extends Pair<T, T> {
  const Couple(super.first, super.second);

  @override
  String toString() {
    return 'Couple<$T>[$first, $second]';
  }

  Couple<S> map<S>(S Function(T) mapper) {
    return Couple(mapper.call(first), mapper.call(second));
  }

  bool both(bool Function(T) test) {
    return test.call(first) && test.call(second);
  }

  bool either(bool Function(T) test) {
    return test.call(first) || test.call(second);
  }
}

extension CouplableList<E> on List<E> {
  Couple<E> toCouple() {
    if (length != 2) {
      throw "Invalid list length";
    }
    return Couple(this[0], this[1]);
  }
}

extension U8S8 on Uint8 {
  Int8 get s8 => value > 0x7f ? Int8(value - 0x100) : Int8(value);
}

extension S8U8 on Int8 {
  Uint8 get u8 => value < 0 ? Uint8(value + 0x100) : Uint8(value);
}

extension U16S16 on Uint16 {
  Int16 get s16 => value > 0x7fff ? Int16(value - 0x10000) : Int16(value);
}

extension S16U16 on Int16 {
  Uint16 get u16 => value < 0 ? Uint16(value + 0x10000) : Uint16(value);
}

extension IntConverter on int {
  Int8 get s8 => Int8(this);
  Uint8 get u8 => Uint8(this);

  Int16 get s16 => Int16(this);
  Uint16 get u16 => Uint16(this);

  core.bool get bool => this > 0;
}

extension BoolConverter on bool {
  core.int get int => this ? 1 : 0;
}

class Uint8Couple extends Couple<Uint8> {
  const Uint8Couple(Uint8 high, Uint8 low) : super(high, low);
  Uint8Couple.fromU16(Uint16 v) : super(((v.value >> 8) & 0xff).u8, (v.value & 0xff).u8);
  Uint8 get high => first;
  Uint8 get low => second;

  static const Uint8Couple zero = Uint8Couple(Uint8.zero, Uint8.zero);
}

int overflowU16(int x) {
  return x & 0xffff;
}

int overflowU8(int x) {
  return x & 0xff;
}
