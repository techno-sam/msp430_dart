/*
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