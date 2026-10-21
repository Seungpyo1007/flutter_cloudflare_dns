import 'dns_record.dart';
import 'dns_text.dart';

/// A line of a zone file that [DnsZoneFile.parse] could not turn into a
/// record.
class DnsZoneFileIssue {
  /// Creates an issue.
  const DnsZoneFileIssue({
    required this.line,
    required this.code,
    required this.message,
  });

  /// 1-based line number where the entry starts.
  final int line;

  /// Machine-readable issue code: `unsupported_type`, `unsupported_class`,
  /// `unsupported_directive`, `missing_owner`, `missing_type`, or
  /// `invalid_rdata`.
  final String code;

  /// Human-readable explanation.
  final String message;
}

/// Records and issues read from a zone file.
class DnsZoneFileResult {
  /// Creates a result.
  const DnsZoneFileResult({required this.records, required this.issues});

  /// Records of supported types, with fully qualified names.
  final List<DnsRecord> records;

  /// Entries that were skipped.
  final List<DnsZoneFileIssue> issues;
}

/// Reads and writes BIND zone files (RFC 1035 master file format).
///
/// The output matches Cloudflare's own DNS export: absolute names, `IN`, and
/// a `cf_tags=cf-proxied:...` comment on proxiable records, so files move
/// between this package and the Cloudflare dashboard in both directions.
abstract final class DnsZoneFile {
  /// Writes [records] as a zone file for [origin], such as `example.com`.
  ///
  /// Names and targets are written fully qualified. Cloudflare's automatic
  /// TTL is written as `1`.
  static String encode(Iterable<DnsRecord> records, {required String origin}) {
    final zone = _trimDot(origin);
    final b = StringBuffer()
      ..writeln(';; Zone file for $zone, exported by flutter_cloudflare_dns.')
      ..writeln('\$ORIGIN $zone.');
    for (final record in records) {
      final owner = '${_absolute(record.name, zone)}.';
      final rdata = switch (record.type) {
        DnsRecordType.a || DnsRecordType.aaaa => record.content.trim(),
        DnsRecordType.cname ||
        DnsRecordType.ns ||
        DnsRecordType.ptr => _fqdn(record.content, zone),
        DnsRecordType.txt => _txt(record.content),
        DnsRecordType.mx =>
          '${record.priority ?? 0} ${_fqdn(record.content, zone)}',
        DnsRecordType.srv =>
          '${record.priority ?? 0} ${record.weight ?? 0} ${record.port ?? 0} '
              '${_fqdn(record.target ?? '', zone)}',
        DnsRecordType.caa =>
          '${record.caaFlags ?? 0} ${record.caaTag} '
              '"${_escape(record.caaValue ?? '')}"',
        DnsRecordType.https || DnsRecordType.svcb =>
          '${record.priority ?? 0} '
                  '${record.target == '.' ? '.' : _fqdn(record.target ?? '', zone)} '
                  '${record.svcParams ?? ''}'
              .trim(),
      };
      final proxiable = switch (record.type) {
        DnsRecordType.a || DnsRecordType.aaaa || DnsRecordType.cname => true,
        _ => false,
      };
      final tags = proxiable && record.proxied != null
          ? ' ; cf_tags=cf-proxied:${record.proxied}'
          : '';
      b.writeln(
        '$owner\t${record.ttl}\tIN\t${record.type.wireName}\t$rdata$tags',
      );
    }
    return b.toString();
  }

  /// Reads a zone file whose relative names are relative to [origin].
  ///
  /// Handles `$ORIGIN`, `$TTL`, `@`, blank owners, parentheses, comments,
  /// and quoted, multi-string TXT values. Records without a TTL get the
  /// `$TTL` value, or [defaultTtl] (Cloudflare's automatic TTL) without one.
  /// Unsupported types such as SOA are reported in
  /// [DnsZoneFileResult.issues] and skipped.
  static DnsZoneFileResult parse(
    String text, {
    required String origin,
    int defaultTtl = 1,
  }) {
    var zone = _trimDot(origin);
    int? zoneTtl;
    String? lastOwner;
    final records = <DnsRecord>[];
    final issues = <DnsZoneFileIssue>[];
    void skip(_Entry entry, String code, String message) => issues.add(
      DnsZoneFileIssue(line: entry.line, code: code, message: message),
    );

    for (final entry in _entries(text)) {
      final tokens = entry.tokens;
      if (tokens.isEmpty) continue;

      final first = tokens.first;
      if (!entry.indented && !first.quoted && first.text.startsWith(r'$')) {
        final directive = first.text.toUpperCase();
        final argument = tokens.length > 1 ? tokens[1].text : null;
        if (directive == r'$ORIGIN' && argument != null) {
          zone = _name(argument, zone);
        } else if (directive == r'$TTL' && _ttl(argument) != null) {
          zoneTtl = _ttl(argument);
        } else {
          skip(
            entry,
            'unsupported_directive',
            '${first.text} is not supported.',
          );
        }
        continue;
      }

      var index = 0;
      final String owner;
      if (entry.indented) {
        if (lastOwner == null) {
          skip(entry, 'missing_owner', 'The first record needs a name.');
          continue;
        }
        owner = lastOwner;
      } else {
        owner = _name(first.text, zone);
        index = 1;
      }
      lastOwner = owner;

      int? ttl;
      var recordClass = 'IN';
      for (var i = 0; i < 2 && index < tokens.length; i++) {
        final token = tokens[index].text;
        if (ttl == null && _ttl(token) != null) {
          ttl = _ttl(token);
        } else if (_classes.contains(token.toUpperCase())) {
          recordClass = token.toUpperCase();
        } else {
          break;
        }
        index++;
      }
      if (index >= tokens.length) {
        skip(entry, 'missing_type', 'No record type for $owner.');
        continue;
      }
      if (recordClass != 'IN') {
        skip(entry, 'unsupported_class', 'Only IN records are supported.');
        continue;
      }
      final typeName = tokens[index].text.toUpperCase();
      final type = DnsRecordType.tryParse(typeName);
      if (type == null) {
        skip(entry, 'unsupported_type', '$typeName $owner is not supported.');
        continue;
      }
      final record = _record(
        type,
        owner,
        ttl ?? zoneTtl ?? defaultTtl,
        tokens.sublist(index + 1),
        zone,
        entry.comment,
      );
      if (record == null) {
        skip(entry, 'invalid_rdata', '$typeName $owner has invalid data.');
      } else {
        records.add(record);
      }
    }
    return DnsZoneFileResult(records: records, issues: issues);
  }

  static const _classes = <String>{'IN', 'CH', 'HS', 'CS'};

  static DnsRecord? _record(
    DnsRecordType type,
    String name,
    int ttl,
    List<_Token> rdata,
    String zone,
    String comment,
  ) {
    String at(int i) => rdata[i].text;
    int? number(int i) => int.tryParse(at(i));
    final proxied = RegExp(
      r'cf-proxied:(true|false)',
    ).firstMatch(comment)?.group(1);
    switch (type) {
      case DnsRecordType.a || DnsRecordType.aaaa:
        if (rdata.length != 1) return null;
        return DnsRecord(
          type: type,
          name: name,
          content: at(0),
          ttl: ttl,
          proxied: proxied == null ? null : proxied == 'true',
        );
      case DnsRecordType.cname || DnsRecordType.ns || DnsRecordType.ptr:
        if (rdata.length != 1) return null;
        return DnsRecord(
          type: type,
          name: name,
          content: _name(at(0), zone),
          ttl: ttl,
          proxied: type == DnsRecordType.cname && proxied != null
              ? proxied == 'true'
              : null,
        );
      case DnsRecordType.txt:
        if (rdata.isEmpty) return null;
        // Quoted character-strings are concatenated, as DNS does on lookup.
        final content = rdata.every((token) => token.quoted)
            ? rdata.map((token) => token.text).join()
            : rdata.map((token) => token.text).join(' ');
        return DnsRecord(type: type, name: name, content: content, ttl: ttl);
      case DnsRecordType.mx:
        if (rdata.length != 2 || number(0) == null) return null;
        return DnsRecord.mx(
          name: name,
          priority: number(0)!,
          mailServer: _name(at(1), zone),
          ttl: ttl,
        );
      case DnsRecordType.srv:
        if (rdata.length != 4 || ![0, 1, 2].every((i) => number(i) != null)) {
          return null;
        }
        return DnsRecord.srv(
          name: name,
          priority: number(0)!,
          weight: number(1)!,
          port: number(2)!,
          target: _name(at(3), zone),
          ttl: ttl,
        );
      case DnsRecordType.caa:
        if (rdata.length != 3 || number(0) == null) return null;
        return DnsRecord.caa(
          name: name,
          flags: number(0)!,
          tag: at(1).toLowerCase(),
          value: at(2),
          ttl: ttl,
        );
      case DnsRecordType.https || DnsRecordType.svcb:
        if (rdata.length < 2 || number(0) == null) return null;
        final target = at(1) == '.' ? '.' : _name(at(1), zone);
        // Keep the quotes around values such as alpn="h3,h2".
        final params = rdata.skip(2).map((token) => token.raw).join(' ');
        return type == DnsRecordType.https
            ? DnsRecord.https(
                name: name,
                priority: number(0)!,
                target: target,
                params: params,
                ttl: ttl,
              )
            : DnsRecord.svcb(
                name: name,
                priority: number(0)!,
                target: target,
                params: params,
                ttl: ttl,
              );
    }
  }

  /// Splits [text] into entries, joining parenthesized lines.
  static List<_Entry> _entries(String text) {
    final entries = <_Entry>[];
    _Entry? open;
    var depth = 0;
    final lines = text.split(RegExp(r'\r?\n'));
    for (var number = 1; number <= lines.length; number++) {
      final line = lines[number - 1];
      final entry =
          open ??
          _Entry(line: number, indented: line.startsWith(RegExp(r'[ \t]')));
      var i = 0;
      while (i < line.length) {
        final char = line[i];
        if (char == ' ' || char == '\t') {
          i++;
        } else if (char == ';') {
          entry.comment += line.substring(i + 1);
          break;
        } else if (char == '(') {
          depth++;
          i++;
        } else if (char == ')') {
          if (depth > 0) depth--;
          i++;
        } else if (char == '"') {
          final start = i;
          final read = readQuotedString(line, i);
          i = read.end;
          entry.tokens.add(
            _Token(read.text, quoted: true, raw: line.substring(start, i)),
          );
        } else {
          final start = i;
          var inQuotes = false;
          // An unquoted token ends at whitespace, but `alpn="h3, h2"` keeps
          // its quoted part.
          while (i < line.length) {
            final c = line[i];
            if (c == '"') inQuotes = !inQuotes;
            if (!inQuotes &&
                (c == ' ' || c == '\t' || c == ';' || c == '(' || c == ')')) {
              break;
            }
            i++;
          }
          final raw = line.substring(start, i);
          entry.tokens.add(_Token(raw, quoted: false, raw: raw));
        }
      }
      if (depth > 0) {
        open = entry;
      } else {
        open = null;
        entries.add(entry);
      }
    }
    if (open != null) entries.add(open);
    return entries;
  }

  static int? _ttl(String? value) {
    if (value == null) return null;
    if (RegExp(r'^\d+$').hasMatch(value)) return int.parse(value);
    // BIND units, e.g. 1h30m.
    final units = <String, int>{
      's': 1,
      'm': 60,
      'h': 3600,
      'd': 86400,
      'w': 604800,
    };
    final parts = RegExp(r'(\d+)([smhdw])').allMatches(value.toLowerCase());
    if (parts.isEmpty || parts.map((m) => m[0]).join() != value.toLowerCase()) {
      return null;
    }
    return parts.fold<int>(
      0,
      (sum, m) => sum + int.parse(m[1]!) * units[m[2]]!,
    );
  }

  /// Resolves a zone-file name: `@` is [zone], a trailing dot is absolute,
  /// anything else is relative to [zone].
  static String _name(String value, String zone) {
    if (value == '@') return zone;
    if (value.endsWith('.')) return _trimDot(value);
    return '$value.$zone';
  }

  /// Makes a record name from this package absolute: `@` is [zone], and a
  /// name not already inside [zone] is relative to it.
  static String _absolute(String value, String zone) {
    final name = value.trim();
    if (name.isEmpty || name == '@') return zone;
    if (name.endsWith('.')) return _trimDot(name);
    final lower = name.toLowerCase();
    final zoneLower = zone.toLowerCase();
    if (lower == zoneLower || lower.endsWith('.$zoneLower')) return name;
    return '$name.$zone';
  }

  /// Hostnames from the Cloudflare API are already fully qualified.
  static String _fqdn(String value, String zone) {
    final name = value.trim();
    if (name == '@') return '$zone.';
    return name.endsWith('.') ? name : '$name.';
  }

  static String _txt(String content) {
    final value = content.trim();
    // Already in zone-file form, as Cloudflare returns some TXT content.
    if (RegExp(
      r'^"(?:[^"\\]|\\.)*"(?:\s+"(?:[^"\\]|\\.)*")*$',
    ).hasMatch(value)) {
      return value;
    }
    // One character-string holds at most 255 bytes; split longer values
    // without cutting a UTF-8 sequence in half.
    return splitUtf8(value).map((chunk) => '"${_escape(chunk)}"').join(' ');
  }

  static String _escape(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

  static String _trimDot(String value) =>
      value.trim().replaceFirst(RegExp(r'\.$'), '');
}

class _Entry {
  _Entry({required this.line, required this.indented});

  final int line;
  final bool indented;
  final List<_Token> tokens = <_Token>[];
  String comment = '';
}

class _Token {
  const _Token(this.text, {required this.quoted, required this.raw});

  /// Unquoted, unescaped value.
  final String text;
  final bool quoted;

  /// The token as written.
  final String raw;
}
