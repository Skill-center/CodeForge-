/// The large files of the large-file gate (Phase 2 W7,
/// integration_test/large_files_test.dart), which Settings → Developer →
/// Create large test files writes as well (Phase 3 W1), byte for byte: the
/// same generator, the same sizes. test/core/large_samples_test.dart pins
/// each file's SHA-256, computed from editor/bench/samples.ts, where the
/// generator comes from.
library;

import 'dart:math' as math;

import '../files/text_codec.dart';
import 'large_files.dart';

const int _mib = 1024 * 1024;

/// One generated file: its name, and the generator's target size.
final class LargeSample {
  const LargeSample(this.name, this.chars);

  final String name;

  /// What [largeJavaScript] is asked for: the text is at least this long,
  /// cut at the next line end. ASCII, so its characters are its bytes.
  final int chars;
}

/// The sizes of the gate's files, in MiB.
const List<int> largeSampleSizesMiB = [1, 5, 10];

/// The largest `.js` file the large-file policy still highlights: the
/// generator overshoots by less than a line.
const String largeLimitName = 'large_${plainTextAboveChars ~/ 1024}kb.js';
const int largeLimitChars = plainTextAboveChars - 128;

/// The target for [mib]: the 10 MiB files stop just under the size cap,
/// which the full 10 MiB plus the generator's last line would pass.
int largeSampleChars(int mib) => math.min(mib * _mib, maxTextFileBytes - 128);

/// The two files of each size: highlighted as JavaScript up to the policy's
/// limit, and plain text always.
List<String> largeSampleNames(int mib) => [
  'large_${mib}mb.js',
  'large_${mib}mb.txt',
];

/// All seven files, smallest first.
final List<LargeSample> largeSamples = List.unmodifiable([
  const LargeSample(largeLimitName, largeLimitChars),
  for (final mib in largeSampleSizesMiB)
    for (final name in largeSampleNames(mib))
      LargeSample(name, largeSampleChars(mib)),
]);

/// editor/bench/samples.ts `largeJavaScript`, ported: at least [chars]
/// characters of ASCII JavaScript, cut at a line end. Blocks differ by
/// number, so no two lines of neighbouring blocks are identical.
String largeJavaScript(int chars) {
  final out = StringBuffer();
  var size = 0;
  for (var n = 0; size < chars; n += 1) {
    final block =
        '// Block $n: generated for the large-file benchmark.\n'
        'export function compute$n(items, factor = ${n % 97}) {\n'
        '  const result = [];\n'
        '  for (let i = 0; i < items.length; i += 1) {\n'
        '    const value = items[i] * factor + $n;\n'
        '    if (value % 2 === 0) {\n'
        "      result.push({ id: i, value, label: 'item-' + i + '-$n' });\n"
        '    } else {\n'
        '      result.push(null); // odd values are skipped\n'
        '    }\n'
        '  }\n'
        '  return result.filter(Boolean);\n'
        '}\n'
        '\n';
    out.write(block);
    size += block.length;
  }
  final text = out.toString();
  final cut = text.indexOf('\n', chars - 1);
  return cut < 0 ? text : text.substring(0, cut + 1);
}
