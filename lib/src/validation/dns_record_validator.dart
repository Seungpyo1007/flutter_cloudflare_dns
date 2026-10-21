import '../models/dns_health.dart';
import '../models/dns_record.dart';

/// Validates supported DNS records before a write request.
abstract final class DnsRecordValidator {
  /// Returns all validation issues for [record].
  static List<DnsIssue> validate(DnsRecord record) {
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
      add('invalid_name', 'Enter a valid DNS record name.');
    }
    if (record.ttl != 1 && record.ttl < 60) {
      add('invalid_ttl', 'TTL must be automatic (1) or at least 60 seconds.');
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
        }
      case DnsRecordType.srv:
        if (!_inRange(record.priority, 0, 65535)) {
          add('invalid_priority', 'SRV priority must be between 0 and 65535.');
        }
        if (!_inRange(record.weight, 0, 65535)) {
          add('invalid_weight', 'SRV weight must be between 0 and 65535.');
        }
        if (!_inRange(record.port, 1, 65535)) {
          add('invalid_port', 'SRV port must be between 1 and 65535.');
        }
        if (!_validName(record.target ?? '')) {
          add('invalid_target', 'Enter a valid SRV target hostname.');
        }
      case DnsRecordType.mx:
        if (!_inRange(record.priority, 0, 65535)) {
          add('invalid_priority', 'MX priority must be between 0 and 65535.');
        }
        if (!_validName(record.content)) {
          add('invalid_target', 'Enter a valid mail server hostname.');
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
        // Alias mode (priority 0) only points at another name (RFC 9460).
        if (record.priority == 0 &&
            (record.svcParams ?? '').trim().isNotEmpty) {
          add(
            'alias_with_params',
            '$label alias records (priority 0) cannot have parameters.',
          );
        }
      case DnsRecordType.ptr:
        if (!_validName(record.content)) {
          add('invalid_target', 'Enter a valid PTR target hostname.');
        }
    }
    return issues;
  }

  /// Throws [DnsValidationException] when [record] is invalid.
  static void validateOrThrow(DnsRecord record) {
    final issues = validate(record);
    if (issues.isNotEmpty) throw DnsValidationException(issues);
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
  static bool _validName(
    String value, {
    bool allowUnderscore = false,
    bool allowWildcard = false,
  }) {
    final normalized = value.trim().replaceFirst(RegExp(r'\.$'), '');
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
