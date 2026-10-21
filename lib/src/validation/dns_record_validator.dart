import 'dart:convert';

import '../models/dns_health.dart';
import '../models/dns_name.dart';
import '../models/dns_record.dart';
import '../models/dns_text.dart';

/// Plan-dependent Cloudflare limits used by [DnsRecordValidator].
class DnsRecordPolicy {
  /// Creates a policy. The defaults match non-Enterprise Cloudflare zones.
  const DnsRecordPolicy({this.minTtl = 60, this.maxTtl = 86400});

  /// Enterprise zones allow TTLs down to 30 seconds.
  static const DnsRecordPolicy enterprise = DnsRecordPolicy(minTtl: 30);

  /// Shortest TTL in seconds other than automatic (`1`).
  final int minTtl;

  /// Longest TTL in seconds.
  final int maxTtl;
}

/// Validates supported DNS records before a write request.
abstract final class DnsRecordValidator {
  /// Largest wire format size of one DNS record that Cloudflare accepts.
  static const int maxRecordBytes = 4096;

  /// Largest combined content length of records with the same name and type.
  static const int maxRecordSetLength = 8192;

  /// Returns all validation issues for [record].
  ///
  /// Names may be internationalized: they are checked in their Punycode
  /// form, as [DnsRecord.toCloudflareJson] sends them.
  static List<DnsIssue> validate(
    DnsRecord record, {
    DnsRecordPolicy policy = const DnsRecordPolicy(),
  }) {
    final issues = <DnsIssue>[];
    void add(String code, String message) => issues.add(
      DnsIssue(
        code: code,
        message: message,
        severity: DnsIssueSeverity.error,
        recordName: record.name,
        recordType: record.type,
      ),
    );

    // Service and verification names such as `_dmarc` or `_minecraft._tcp`
    // need underscores; `@` is Cloudflare's shorthand for the zone apex.
    final allowUnderscore = switch (record.type) {
      DnsRecordType.srv ||
      DnsRecordType.txt ||
      DnsRecordType.cname ||
      DnsRecordType.https ||
      DnsRecordType.svcb => true,
      DnsRecordType.a ||
      DnsRecordType.aaaa ||
      DnsRecordType.mx ||
      DnsRecordType.caa ||
      DnsRecordType.ns ||
      DnsRecordType.ptr => false,
    };
    if (record.name.trim() != '@' &&
        !_validName(
          record.name,
          allowUnderscore: allowUnderscore,
          allowWildcard: true,
        )) {
      add(
        'invalid_name',
        'Enter a valid DNS record name: labels of letters, digits, and '
            'hyphens up to 63 characters, 253 in total. Internationalized '
            'names are converted to Punycode (xn--).',
      );
    }
    if (record.ttl != 1 &&
        (record.ttl < policy.minTtl || record.ttl > policy.maxTtl)) {
      add(
        'invalid_ttl',
        'TTL must be automatic (1) or between ${policy.minTtl} and '
            '${policy.maxTtl} seconds.',
      );
    }
    if (record.proxied == true && record.ttl != 1) {
      add('proxied_ttl', 'Proxied records always use automatic TTL.');
    }
    // Cloudflare limits: 20 tags, names of letters/digits/-/_ up to 32
    // characters, values up to 100, comments up to 500 (100 on Free).
    if (record.tags.length > 20) {
      add('too_many_tags', 'A record can have at most 20 tags.');
    }
    if (!record.tags.every(_validTag)) {
      add(
        'invalid_tag',
        'Use tags like name or name:value (name up to 32 letters, digits, '
            '- or _; value up to 100 characters).',
      );
    }
    if ((record.comment?.length ?? 0) > 500) {
      add('comment_too_long', 'Comments can be at most 500 characters.');
    }

    switch (record.type) {
      case DnsRecordType.a:
        if (!_validIpv4(record.content)) {
          add('invalid_ipv4', 'Enter a valid IPv4 address.');
        }
      case DnsRecordType.aaaa:
        if (!_validIpv6(record.content)) {
          add('invalid_ipv6', 'Enter a valid IPv6 address.');
        }
      case DnsRecordType.cname:
        if (!_validName(record.content)) {
          add('invalid_target', 'Enter a valid CNAME target hostname.');
        }
      case DnsRecordType.txt:
        if (record.content.trim().isEmpty) {
          add('empty_txt', 'TXT content cannot be empty.');
        } else if (txtWireLength(record.content) > maxRecordBytes) {
          add(
            'txt_too_long',
            'TXT content is longer than the $maxRecordBytes-byte limit '
                'for one record.',
          );
        }
      case DnsRecordType.srv:
        // A target of `.` means the service is not available (RFC 2782).
        final target = record.target?.trim() ?? '';
        if (!_inRange(record.priority, 0, 65535)) {
          add('invalid_priority', 'SRV priority must be between 0 and 65535.');
        }
        if (!_inRange(record.weight, 0, 65535)) {
          add('invalid_weight', 'SRV weight must be between 0 and 65535.');
        }
        if (!_inRange(record.port, target == '.' ? 0 : 1, 65535)) {
          add('invalid_port', 'SRV port must be between 1 and 65535.');
        }
        if (target != '.' && !_validName(target)) {
          add(
            'invalid_target',
            'Enter a valid SRV target hostname, or `.` for no service.',
          );
        }
      case DnsRecordType.mx:
        if (!_inRange(record.priority, 0, 65535)) {
          add('invalid_priority', 'MX priority must be between 0 and 65535.');
        }
        // `0 .` is a null MX: the domain accepts no mail (RFC 7505).
        if (record.content.trim() == '.') {
          if (record.priority != 0) {
            add('invalid_null_mx', 'A null MX (`.`) must have priority 0.');
          }
        } else if (!_validName(record.content)) {
          add(
            'invalid_target',
            'Enter a valid mail server hostname, or `.` for no mail.',
          );
        }
      case DnsRecordType.caa:
        if (!_inRange(record.caaFlags, 0, 255)) {
          add('invalid_flags', 'CAA flags must be between 0 and 255.');
        }
        if (!caaPropertyTags.contains(record.caaTag)) {
          add('invalid_caa_tag', 'CAA tag must be issue, issuewild, or iodef.');
        }
        final value = record.caaValue?.trim() ?? '';
        if (value.isEmpty || value.contains('"')) {
          add('invalid_caa_value', 'Enter a CAA value without quotes.');
        }
      case DnsRecordType.ns:
        if (!_validName(record.content)) {
          add('invalid_target', 'Enter a valid nameserver hostname.');
        }
      case DnsRecordType.https || DnsRecordType.svcb:
        final label = record.type.wireName;
        if (!_inRange(record.priority, 0, 65535)) {
          add(
            'invalid_priority',
            '$label priority must be between 0 and 65535.',
          );
        }
        // `.` stands for the record's own name.
        final target = record.target?.trim() ?? '';
        if (target != '.' && !_validName(target)) {
          add('invalid_target', 'Enter a valid $label target or `.`.');
        }
        final params = (record.svcParams ?? '').trim();
        // Alias mode (priority 0) only points at another name (RFC 9460).
        if (record.priority == 0 && params.isNotEmpty) {
          add(
            'alias_with_params',
            '$label alias records (priority 0) cannot have parameters.',
          );
        } else {
          final error = svcParamsError(params);
          if (error != null) add('invalid_svc_params', error);
        }
      case DnsRecordType.ptr:
        if (!_validName(record.content)) {
          add('invalid_target', 'Enter a valid PTR target hostname.');
        }
    }
    return issues;
  }

  /// Throws [DnsValidationException] when [record] is invalid.
  static void validateOrThrow(
    DnsRecord record, {
    DnsRecordPolicy policy = const DnsRecordPolicy(),
  }) {
    final issues = validate(record, policy: policy);
    if (issues.isNotEmpty) throw DnsValidationException(issues);
  }

  /// Checks rules that span records in [zoneName]: a CNAME cannot share its
  /// name with any other record, identical records are rejected, a null MX
  /// must be the only MX for its name, and records with the same name and
  /// type may hold at most [maxRecordSetLength] characters together.
  ///
  /// A CNAME at the apex gets a `cname_flattened` info issue, because
  /// Cloudflare answers it with the target's addresses. Each issue names the
  /// later record of a conflicting pair, so an import can skip it.
  static List<DnsIssue> validateZone(
    Iterable<DnsRecord> records, {
    required String zoneName,
  }) => <DnsIssue>[
    for (final finding in _zoneFindings(records, zoneName)) finding.issue,
  ];

  static List<({DnsRecord record, DnsIssue issue})> _zoneFindings(
    Iterable<DnsRecord> records,
    String zoneName,
  ) {
    final zone = _bare(DnsName.toAscii(zoneName));
    final issues = <({DnsRecord record, DnsIssue issue})>[];
    final byName = <String, List<DnsRecord>>{};
    final seen = <String>{};
    for (final record in records) {
      final name = recordKeyName(record.name, zone);
      ({DnsRecord record, DnsIssue issue}) issue(
        String code,
        String message, [
        DnsIssueSeverity severity = DnsIssueSeverity.error,
      ]) => (
        record: record,
        issue: DnsIssue(
          code: code,
          message: message,
          severity: severity,
          recordName: record.name,
          recordType: record.type,
        ),
      );

      final others = byName.putIfAbsent(name, () => <DnsRecord>[]);
      final key = '${record.type.wireName}|${record.canonicalContent}';
      if (!seen.add('$name|$key')) {
        issues.add(
          issue(
            'duplicate_record',
            '${record.type.wireName} $name ${record.content} is listed twice.',
          ),
        );
        continue;
      }
      if (record.type == DnsRecordType.cname
          ? others.isNotEmpty
          : others.any((other) => other.type == DnsRecordType.cname)) {
        issues.add(
          issue(
            'cname_conflict',
            'A CNAME at $name cannot share its name with other records.',
          ),
        );
      }
      if (record.type == DnsRecordType.mx) {
        final mx = others.where((other) => other.type == DnsRecordType.mx);
        final isNull = record.content.trim() == '.';
        if (mx.isNotEmpty &&
            (isNull || mx.any((other) => other.content.trim() == '.'))) {
          issues.add(
            issue(
              'null_mx_conflict',
              'A null MX must be the only MX record for $name.',
            ),
          );
        }
      }
      final sameType = others.where((other) => other.type == record.type);
      final length = sameType.fold<int>(
        record.content.length,
        (sum, other) => sum + other.content.length,
      );
      if (length > maxRecordSetLength) {
        issues.add(
          issue(
            'record_set_too_long',
            '${record.type.wireName} records at $name exceed '
                '$maxRecordSetLength characters together.',
          ),
        );
      }
      if (record.type == DnsRecordType.cname && name == zone) {
        issues.add(
          issue(
            'cname_flattened',
            'A CNAME at the apex is flattened: Cloudflare answers with the '
                "target's A and AAAA records.",
            DnsIssueSeverity.info,
          ),
        );
      }
      others.add(record);
    }
    return issues;
  }

  /// Issues [validateZone] reports for [record] when it joins
  /// [existingRecords]. A record with the same id as [record] is treated as
  /// the version being replaced.
  static List<DnsIssue> validateInZone(
    DnsRecord record,
    Iterable<DnsRecord> existingRecords, {
    required String zoneName,
  }) {
    final others = existingRecords.where(
      (other) => record.id == null || other.id != record.id,
    );
    return <DnsIssue>[
      for (final finding in _zoneFindings(<DnsRecord>[
        ...others,
        record,
      ], zoneName))
        if (identical(finding.record, record) &&
            finding.issue.severity == DnsIssueSeverity.error)
          finding.issue,
    ];
  }

  /// Fully qualified, lowercase, Punycode form of [name] in [zone], used to
  /// compare record names.
  static String recordKeyName(String name, String zone) {
    final value = _bare(DnsName.toAscii(name));
    if (value.isEmpty || value == '@') return zone;
    if (value == zone || value.endsWith('.$zone')) return value;
    return '$value.$zone';
  }

  static String _bare(String name) =>
      name.trim().toLowerCase().replaceFirst(RegExp(r'\.$'), '');

  /// Approximate wire size of TXT [content]: every character-string of at
  /// most 255 bytes plus its length byte.
  static int txtWireLength(String content) => splitUtf8(
    decodeTxtContent(content),
  ).fold<int>(0, (sum, chunk) => sum + utf8.encode(chunk).length + 1);

  /// Describes what is wrong with HTTPS or SVCB service parameters in
  /// presentation format (RFC 9460), such as `alpn="h3,h2" port=8443`, or
  /// returns null when they are valid.
  static String? svcParamsError(String params) {
    final tokens = _svcTokens(params);
    if (tokens == null) return 'Close every quote in the parameters.';
    final keys = <String>{};
    final values = <String, String>{};
    for (final token in tokens) {
      final equals = token.indexOf('=');
      final key = (equals < 0 ? token : token.substring(0, equals))
          .toLowerCase();
      final hasValue = equals >= 0;
      var value = hasValue ? token.substring(equals + 1) : '';
      if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
        value = value.substring(1, value.length - 1);
      }
      final keyNumber = RegExp(r'^key(\d{1,5})$').firstMatch(key);
      final known = _svcKeys.contains(key);
      if (!known &&
          (keyNumber == null || int.parse(keyNumber.group(1)!) > 65535)) {
        return 'Unknown parameter "$key". Use ${_svcKeys.join(', ')}, or '
            'keyNNNNN.';
      }
      if (!keys.add(key)) return 'Parameter "$key" appears more than once.';
      if (key == 'no-default-alpn') {
        if (hasValue) return 'no-default-alpn takes no value.';
        continue;
      }
      if (known && value.isEmpty) return 'Parameter "$key" needs a value.';
      values[key] = value;
      final items = value.split(',');
      switch (key) {
        case 'port':
          final port = int.tryParse(value);
          if (port == null || port < 0 || port > 65535) {
            return 'port must be between 0 and 65535.';
          }
        case 'ipv4hint':
          if (!items.every(_validIpv4)) {
            return 'ipv4hint must list IPv4 addresses.';
          }
        case 'ipv6hint':
          if (!items.every(_validIpv6)) {
            return 'ipv6hint must list IPv6 addresses.';
          }
        case 'alpn' || 'mandatory':
          if (items.any((item) => item.isEmpty)) {
            return '$key must be a comma-separated list.';
          }
      }
    }
    for (final key in (values['mandatory'] ?? '').split(',')) {
      if (key.isNotEmpty && !keys.contains(key.toLowerCase())) {
        return 'mandatory lists "$key", which is not set.';
      }
    }
    if (keys.contains('no-default-alpn') && !keys.contains('alpn')) {
      return 'no-default-alpn needs alpn.';
    }
    return null;
  }

  static const _svcKeys = <String>[
    'mandatory',
    'alpn',
    'no-default-alpn',
    'port',
    'ipv4hint',
    'ech',
    'ipv6hint',
    'dohpath',
  ];

  /// Splits [params] at whitespace outside quotes, or returns null when a
  /// quote is not closed.
  static List<String>? _svcTokens(String params) {
    final tokens = <String>[];
    final token = StringBuffer();
    var quoted = false;
    for (var i = 0; i < params.length; i++) {
      final char = params[i];
      if (char == r'\' && i + 1 < params.length) {
        token
          ..write(char)
          ..write(params[++i]);
      } else if (char == '"') {
        quoted = !quoted;
        token.write(char);
      } else if (!quoted && (char == ' ' || char == '\t')) {
        if (token.isNotEmpty) tokens.add(token.toString());
        token.clear();
      } else {
        token.write(char);
      }
    }
    if (quoted) return null;
    if (token.isNotEmpty) tokens.add(token.toString());
    return tokens;
  }

  static bool _validTag(String tag) {
    final colon = tag.indexOf(':');
    final name = colon < 0 ? tag : tag.substring(0, colon);
    final value = colon < 0 ? '' : tag.substring(colon + 1);
    return RegExp(r'^[A-Za-z0-9_-]{1,32}$').hasMatch(name) &&
        value.length <= 100;
  }

  static bool _inRange(int? value, int min, int max) =>
      value != null && value >= min && value <= max;

  /// [allowWildcard] accepts a leading `*` label, as in `*.example.com`.
  /// Internationalized names are checked in Punycode form.
  static bool _validName(
    String value, {
    bool allowUnderscore = false,
    bool allowWildcard = false,
  }) {
    final normalized = DnsName.toAscii(value).replaceFirst(RegExp(r'\.$'), '');
    if (normalized.isEmpty || normalized.length > 253) return false;
    final labelPattern = allowUnderscore
        ? RegExp(r'^[a-zA-Z0-9_](?:[a-zA-Z0-9_-]{0,61}[a-zA-Z0-9_])?$')
        : RegExp(r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$');
    final labels = normalized.split('.');
    if (allowWildcard && labels.first == '*') labels.removeAt(0);
    return labels.every(labelPattern.hasMatch);
  }

  // dart:core's parsers reject leading zeros, signs, and malformed groups,
  // and work on every platform including the web.
  static bool _validIpv4(String value) {
    try {
      Uri.parseIPv4Address(value.trim());
      return true;
    } on FormatException {
      return false;
    }
  }

  static bool _validIpv6(String value) {
    final address = value.trim();
    // A zone index such as `%en0` has no meaning in DNS.
    if (!address.contains(':') || address.contains('%')) return false;
    try {
      Uri.parseIPv6Address(address);
      return true;
    } on FormatException {
      return false;
    }
  }
}

/// Thrown when a record is rejected before a network call.
class DnsValidationException implements Exception {
  /// Creates the exception.
  const DnsValidationException(this.issues);

  /// Validation findings.
  final List<DnsIssue> issues;

  @override
  String toString() => issues.map((issue) => issue.message).join(' ');
}
