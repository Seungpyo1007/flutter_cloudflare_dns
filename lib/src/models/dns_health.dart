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

/// Answers for one record from several public resolvers.
class DnsResolverComparison {
  /// Creates a comparison.
  const DnsResolverComparison({
    required this.name,
    required this.type,
    required this.answers,
    this.failedResolvers = const <String>{},
  });

  /// Queried DNS name.
  final String name;

  /// Queried DNS type.
  final DnsRecordType type;

  /// Answers keyed by resolver label, such as `Cloudflare` or `Google`.
  final Map<String, List<DnsRecord>> answers;

  /// Labels of resolvers whose lookup failed.
  final Set<String> failedResolvers;

  /// Whether every resolver answered and all answers match.
  bool get consistent {
    if (failedResolvers.isNotEmpty) return false;
    final contents = answers.values
        .map((records) => records.map((r) => r.canonicalContent).toSet())
        .toList(growable: false);
    return contents.every(
      (set) =>
          set.length == contents.first.length &&
          set.containsAll(contents.first),
    );
  }
}
