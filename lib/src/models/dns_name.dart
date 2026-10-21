/// Converts internationalized domain names between Unicode and the
/// Punycode (`xn--`) form DNS and the Cloudflare API use (RFC 3492).
///
/// Labels are lowercased before encoding; full IDNA 2008 mapping and
/// validation are not applied, so unusual scripts may still be rejected by
/// Cloudflare.
abstract final class DnsName {
  /// Returns [name] with every non-ASCII label Punycode-encoded, for example
  /// `한국.example.com` becomes `xn--3e0b707e.example.com`. ASCII names are
  /// returned trimmed and otherwise unchanged.
  static String toAscii(String name) {
    final value = name.trim();
    if (_isAscii(value)) return value;
    return value
        .split('.')
        .map(
          (label) =>
              _isAscii(label) ? label : 'xn--${_encode(label.toLowerCase())}',
        )
        .join('.');
  }

  /// Returns [name] with every `xn--` label decoded, for display. Labels that
  /// do not decode are kept as they are.
  static String toUnicode(String name) {
    if (!name.toLowerCase().contains('xn--')) return name;
    return name
        .split('.')
        .map((label) {
          if (!label.toLowerCase().startsWith('xn--')) return label;
          return _decode(label.substring(4).toLowerCase()) ?? label;
        })
        .join('.');
  }

  /// Whether [name] has a non-ASCII or `xn--` label.
  static bool isInternationalized(String name) =>
      !_isAscii(name) || name.toLowerCase().contains('xn--');

  static bool _isAscii(String value) => value.codeUnits.every((c) => c < 0x80);
}

String _encode(String label) {
  final codePoints = label.runes.toList(growable: false);
  final output = StringBuffer();
  for (final codePoint in codePoints) {
    if (codePoint < 0x80) output.writeCharCode(codePoint);
  }
  final basicLength = output.length;
  if (basicLength > 0) output.write('-');

  var handled = basicLength;
  var n = _initialN;
  var delta = 0;
  var bias = _initialBias;
  while (handled < codePoints.length) {
    final next = codePoints
        .where((codePoint) => codePoint >= n)
        .reduce((a, b) => a < b ? a : b);
    delta += (next - n) * (handled + 1);
    n = next;
    for (final codePoint in codePoints) {
      if (codePoint < n) delta++;
      if (codePoint != n) continue;
      var q = delta;
      for (var k = _base; ; k += _base) {
        final t = _threshold(k, bias);
        if (q < t) break;
        output.writeCharCode(_digit(t + (q - t) % (_base - t)));
        q = (q - t) ~/ (_base - t);
      }
      output.writeCharCode(_digit(q));
      bias = _adapt(delta, handled + 1, first: handled == basicLength);
      delta = 0;
      handled++;
    }
    delta++;
    n++;
  }
  return output.toString();
}

/// Decodes a Punycode label without its `xn--` prefix, or returns null when
/// it is malformed.
String? _decode(String input) {
  final dash = input.lastIndexOf('-');
  final output = <int>[if (dash > 0) ...input.substring(0, dash).codeUnits];
  if (output.any((c) => c >= 0x80)) return null;
  var n = _initialN;
  var bias = _initialBias;
  var i = 0;
  var index = dash > 0 ? dash + 1 : 0;
  while (index < input.length) {
    final oldI = i;
    var w = 1;
    for (var k = _base; ; k += _base) {
      if (index >= input.length) return null;
      final digit = _value(input.codeUnitAt(index++));
      if (digit == null) return null;
      i += digit * w;
      final t = _threshold(k, bias);
      if (digit < t) break;
      w *= _base - t;
      if (i > 0x10FFFF * 64) return null;
    }
    bias = _adapt(i - oldI, output.length + 1, first: oldI == 0);
    n += i ~/ (output.length + 1);
    i %= output.length + 1;
    if (n > 0x10FFFF) return null;
    output.insert(i, n);
    i++;
  }
  return String.fromCharCodes(output);
}

const _base = 36;
const _tMin = 1;
const _tMax = 26;
const _skew = 38;
const _damp = 700;
const _initialBias = 72;
const _initialN = 0x80;

int _threshold(int k, int bias) => k <= bias
    ? _tMin
    : k >= bias + _tMax
    ? _tMax
    : k - bias;

/// Digits 0-25 are `a`-`z`, 26-35 are `0`-`9`.
int _digit(int value) => value < 26 ? 0x61 + value : 0x16 + value;

int? _value(int codeUnit) {
  if (codeUnit >= 0x61 && codeUnit <= 0x7a) return codeUnit - 0x61;
  if (codeUnit >= 0x41 && codeUnit <= 0x5a) return codeUnit - 0x41;
  if (codeUnit >= 0x30 && codeUnit <= 0x39) return codeUnit - 0x16;
  return null;
}

int _adapt(int delta, int points, {required bool first}) {
  delta = first ? delta ~/ _damp : delta ~/ 2;
  delta += delta ~/ points;
  var k = 0;
  while (delta > ((_base - _tMin) * _tMax) ~/ 2) {
    delta ~/= _base - _tMin;
    k += _base;
  }
  return k + ((_base - _tMin + 1) * delta) ~/ (delta + _skew);
}
