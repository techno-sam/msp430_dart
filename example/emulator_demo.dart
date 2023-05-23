import 'package:msp430_dart/msp430_dart.dart';

void main() {
  Computer c = Computer();
  c.specialInterrupts = false;

  c.setWord(0x0000, 0x3c07); // jmp     0x10
  c.setWord(0x0010, 0x1085); // swpb    R5
  c.setWord(0x0012, 0xf375); // and.b   #-0x1, r5

  c.setWord(0x0014,
      0xf3f5); // and.b   #-0x1, 25(r5) ; 1st word (has 1 extension word)
  c.setWord(
      0x0016, 0x0019); // and.b   #-0x1, 25(r5) ; 2nd word (extension word)

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