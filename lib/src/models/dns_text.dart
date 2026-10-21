import 'dart:convert';

/// Reads the quoted character-string whose opening `"` is at [start].
///
/// Handles `\"`, `\\`, and `\DDD` escapes; `\DDD` is a byte, so escaped UTF-8
/// sequences decode to the character they spell. [end] is the index after the
/// closing quote, or the end of [source] when the quote is unterminated.
({String text, int end}) readQuotedString(String source, int start) {
  final bytes = <int>[];
  final pending = StringBuffer();
  void flush() {
    if (pending.isEmpty) return;
    bytes.addAll(utf8.encode(pending.toString()));
    pending.clear();
  }

  var i = start + 1;
  while (i < source.length && source[i] != '"') {
    if (source[i] == r'\' && i + 1 < source.length) {
      final digits = RegExp(r'^\d{3}').stringMatch(source.substring(i + 1));
      if (digits != null) {
        flush();
        bytes.add(int.parse(digits) & 0xff);
        i += 4;
        continue;
      }
      i++;
    }
    pending.write(source[i]);
    i++;
  }
  flush();
  return (
    text: utf8.decode(bytes, allowMalformed: true),
    end: i < source.length ? i + 1 : source.length,
  );
}

/// The value TXT [content] spells.
///
/// Content made only of quoted character-strings, such as `"v=DKIM1; p=…"
/// "…rest"`, is unescaped and concatenated, the way DNS clients read a split
/// value. Anything else is returned trimmed, as Cloudflare stores unquoted
/// TXT content.
String decodeTxtContent(String content) {
  final value = content.trim();
  if (!value.startsWith('"')) return value;
  final out = StringBuffer();
  var i = 0;
  while (i < value.length) {
    final char = value[i];
    if (char == ' ' || char == '\t') {
      i++;
    } else if (char == '"') {
      final read = readQuotedString(value, i);
      out.write(read.text);
      i = read.end;
    } else {
      return value;
    }
  }
  return out.toString();
}

/// Splits [value] into chunks of at most [maxBytes] UTF-8 bytes, never
/// inside a character.
List<String> splitUtf8(String value, {int maxBytes = 255}) {
  final chunks = <String>[];
  final chunk = StringBuffer();
  var size = 0;
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    final length = utf8.encode(char).length;
    if (size + length > maxBytes && chunk.isNotEmpty) {
      chunks.add(chunk.toString());
      chunk.clear();
      size = 0;
    }
    chunk.write(char);
    size += length;
  }
  if (chunk.isNotEmpty || chunks.isEmpty) chunks.add(chunk.toString());
  return chunks;
}
