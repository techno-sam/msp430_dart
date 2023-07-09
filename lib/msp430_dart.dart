/// Support for doing something awesome.
///
/// More dartdocs go here.
library msp430_dart;

export 'src/basic_datatypes.dart';
export 'src/colors.dart' show Fore, Back, Style;
export 'src/assembler.dart' show parse, writeCompiledByName, writeCompiled;
export 'src/emulator.dart' show Register, Computer, ExecutionError;

import 'src/regexes.dart';
Regex re = Regex();