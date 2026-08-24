import 'dns_record.dart';

/// Diagnostic issue severity.
enum DnsIssueSeverity { info, warning, error }

/// A stable diagnostic finding suitable for UI or logging.
class DnsIssue {
  /// Creates an issue.
  const DnsIssue({
    required this.code,
    required this.message,
    this.severity = DnsIssueSeverity.warning,
    this.recordName,
    this.recordType,
  });

  /// Machine-readable issue code.
  final String code;

  /// Human-readable explanation.
  final String message;

  /// Issue severity.
  final DnsIssueSeverity severity;

  /// Related record name.
  final String? recordName;

  /// Related record type.
  final DnsRecordType? recordType;
}

/// Result of one public DNS health check.
class DnsHealthReport {
  /// Creates a report.
  const DnsHealthReport({
    required this.domain,
    required this.checkedAt,
    required this.answers,
    required this.issues,
  });

  /// Domain that was checked.
  final String domain;

  /// Time the check completed.
  final DateTime checkedAt;

  /// Answers keyed by `name|TYPE`.
  final Map<String, List<DnsRecord>> answers;

  /// Findings from the check.
  final List<DnsIssue> issues;

  /// Whether the report contains no errors or warnings.
  bool get isHealthy =>
      issues.every((issue) => issue.severity == DnsIssueSeverity.info);

  /// Number of error findings.
  int get errorCount =>
      issues.where((issue) => issue.severity == DnsIssueSeverity.error).length;
}
