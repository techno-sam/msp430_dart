import 'dart:typed_data';

import 'package:msp430_dart/msp430_dart.dart';


void main() async {
  print('${Fore.RED}hi');
  print("this should still be red");
  print("and this${Fore.RESET}. but not ${Back.LIGHTBLUE_EX}this${Style.RESET_ALL}");
  print("\n\n");
  //*
  Uint8List? compiled = parse("""test:
; this is a comment
jmp 0x2
test2: add R12 R1; so is this
add @r14+ r4
jmp test2
jmp 0x12

.data
my_string:
.cstr8 test string

.text

jmp 16
jmp -0x54

.data
.cstr8 next text!
.text

jmp fake
dint ; emulated example
fake: br r7 ; emulated example 2

jmp 0 ; guard against 'executing' data section
""", silent: false);// */
  if (compiled == null) {
    print("Compilation failed");
  } else {
    print("Compilation successful!");
    await writeCompiledByName(compiled, "test_file.bin");
  }
  /*
  await parse(r"""
MOV #0x4400, SP
.define "R6", Test$Macro_1
AdD #10 [Test$Macro_1] ;comment


; test putchar
mov #0xe2, r15
call #putchar
mov #0x9d, r15
call #putchar
mov #0xa4, r15
call #putchar

mov #0xef, r15
call #putchar
mov #0xb8, r15
call #putchar
mov #0x8f, r15
call #putchar

;mov #0xc17d, r15
mov #0xa1, r15
call #putuc16

mov #0x09a0, r15
call #putuc16

mov #0x42, r15
call #putuc16

MOV #72, r15
MOV #0, r15
mov #0xc17b, r15
mov #0x0003, r15
mov #0x0000, r15
print_loop: ADD.w #1, r15
call #putuc16
jmp print_loop

; a comment
  ; more comments
; test weird upper+lowercase mixtures
loop: CmP #11 0(R10)
MOV #test2, R5
push #0x1234
;JmP -0x8
jmp loop
PUsH.b @R5
; test emulated instructions
DINT
tst.B R10
POP 0(R11)

test_on_a_line:       ; and a comment



jmp test
test: PUSH #14
PUSH #154
test2: PUSH #241
JMP test
JMP test2
MOV #-8, test2(R5)
and.b #-0x1, r5
jmp 0x10 ; this outputs correctly, original would have been jmp 0x10 -> to get from input to correct, use this formula: (original - 2) / 2 --> then convert to signed
SWPB R5
and.b #-0x1, 25(r5)
cmp #0x8, r7


; higher-level utility functions
; <putuc16> - send unicode codepoint (16-bit) to console
putuc16:
; input: r15
; if the codepoint is greater than U+007F, we need two passes, and if it's greater than U+07FF, we need three passes
; handle one-pass case first
; store r13, r14 and r15 on stack
push    r13
push    r14
push    r15
; check if codepoint is greater than U+007F
bit     #0xff80, r15
jc      putuc16_2pass
; if not, we can just send it directly
call    #putchar
; restore r14 and r15 from stack
putuc16_cleanup:
pop     r15
pop     r14
pop     r13
ret
; handle two-pass case
putuc16_2pass:
; check if codepoint is greater than U+07FF
bit     #0xf800, r15
jc      putuc16_3pass
; if not, we need two passes
; done like this: 110xxxxx 10xxxxxx
; put 6 bits in r14
mov     r15, r14
and     #0x3f, r14
; put in 10 header
bis     #0x80, r14
; shift r15 right 6 bits
rra     r15
rra     r15
rra     r15
rra     r15
rra     r15
rra     r15
; set 110 header in r15
and     #0x1f, r15
bis     #0xc0, r15
; send high
push    r14
call    #putchar
pop     r14
; send low
mov     r14, r15
call    #putchar
jmp     putuc16_cleanup
; handle three-pass case
putuc16_3pass:
; done like this: 1110xxxx 10xxxxxx 10xxxxxx
; 1110xxxx in r15 (bits 12-15)
; 10xxxxxx in r14 (bits 6-11)
; 10xxxxxx in r13 (bits 0-5)
mov     r15, r14
mov     r15, r13
; setup r13
and     #0x3f, r13
bis     #0x80, r13
; setup r14
; must shift r14 right 6 bits
rra     r14
rra     r14
rra     r14
rra     r14
rra     r14
rra     r14
and     #0x3f, r14
bis     #0x80, r14
; setup r15
; must shift r15 right 12 bits
rra     r15
rra     r15
rra     r15
rra     r15
rra     r15
rra     r15
rra     r15
rra     r15
rra     r15
rra     r15
rra     r15
rra     r15
and     #0x0f, r15
bis     #0xe0, r15
; send high
push    r14
call    #putchar
pop     r14
; send middle
mov     r14, r15
call    #putchar
; send low
mov     r13, r15
call    #putchar
jmp     putuc16_cleanup

; utility functions
; <INT> - send an interrupt
INT:
mov     0x2(sp), r14
push    sr
mov     r14, r15
swpb    r15
mov     r15, sr
bis     #0x8000, sr ; set highest bit of sr to 1
call    #0x10
pop     sr
ret

; <putchar> - send single character to console
putchar:
decd    sp
push    r15
push    #0x0 ; interrupt type
mov     r15, 0x4(sp)
call    #INT
mov     0x4(sp), r15
add     #0x6, sp
ret

""");// */
}
