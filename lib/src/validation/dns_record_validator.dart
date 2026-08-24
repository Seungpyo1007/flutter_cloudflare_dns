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

    if (!_validName(
      record.name,
      allowUnderscore: record.type == DnsRecordType.srv,
    )) {
      add('invalid_name', 'Enter a valid DNS record name.');
    }
    if (record.ttl != 1 && record.ttl < 60) {
      add('invalid_ttl', 'TTL must be automatic (1) or at least 60 seconds.');
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
        if (record.priority == null ||
            record.priority! < 0 ||
            record.priority! > 65535) {
          add('invalid_priority', 'SRV priority must be between 0 and 65535.');
        }
        if (record.weight == null ||
            record.weight! < 0 ||
            record.weight! > 65535) {
          add('invalid_weight', 'SRV weight must be between 0 and 65535.');
        }
        if (record.port == null || record.port! < 1 || record.port! > 65535) {
          add('invalid_port', 'SRV port must be between 1 and 65535.');
        }
        if (!_validName(record.target ?? '')) {
          add('invalid_target', 'Enter a valid SRV target hostname.');
        }
    }
    return issues;
  }

  /// Throws [DnsValidationException] when [record] is invalid.
  static void validateOrThrow(DnsRecord record) {
    final issues = validate(record);
    if (issues.isNotEmpty) throw DnsValidationException(issues);
  }

  static bool _validName(String value, {bool allowUnderscore = false}) {
    final normalized = value.trim().replaceFirst(RegExp(r'\.$'), '');
    if (normalized.isEmpty || normalized.length > 253) return false;
    final labelPattern = allowUnderscore
        ? RegExp(r'^[a-zA-Z0-9_](?:[a-zA-Z0-9_-]{0,61}[a-zA-Z0-9_])?$')
        : RegExp(r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$');
    return normalized.split('.').every(labelPattern.hasMatch);
  }

  static bool _validIpv4(String value) {
    final parts = value.trim().split('.');
    return parts.length == 4 &&
        parts.every((part) {
          final number = int.tryParse(part);
          return number != null && number >= 0 && number <= 255;
        });
  }

  static bool _validIpv6(String value) {
    final normalized = value.trim();
    return normalized.contains(':') &&
        RegExp(r'^[0-9a-fA-F:]+$').hasMatch(normalized) &&
        normalized.length <= 45;
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
