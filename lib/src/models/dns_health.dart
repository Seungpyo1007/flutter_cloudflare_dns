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
    this.dnssecValidated,
  });

  /// Domain that was checked.
  final String domain;

  /// Time the check completed.
  final DateTime checkedAt;

  /// Answers keyed by `name|TYPE`.
  final Map<String, List<DnsRecord>> answers;

  /// Findings from the check.
  final List<DnsIssue> issues;

  /// Whether the resolver validated every answer with DNSSEC (the `AD` flag
  /// of each successful lookup), or null when no lookup succeeded.
  ///
  /// False usually means the zone is not signed, or its DS record is missing
  /// at the registrar.
  final bool? dnssecValidated;

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
    this.nxdomainResolvers = const <String>{},
    this.cnames = const <String, List<DnsRecord>>{},
  });

  /// Queried DNS name.
  final String name;

  /// Queried DNS type.
  final DnsRecordType type;

  /// Answers keyed by resolver label, such as `Cloudflare` or `Google`.
  final Map<String, List<DnsRecord>> answers;

  /// Labels of resolvers whose lookup failed.
  final Set<String> failedResolvers;

  /// Labels of resolvers that answered that the name does not exist
  /// (NXDOMAIN). Their [answers] are empty; they did not fail.
  final Set<String> nxdomainResolvers;

  /// CNAME records each resolver followed to reach [answers], keyed like
  /// [answers]. Empty when the name has no CNAME.
  final Map<String, List<DnsRecord>> cnames;

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

  /// Whether every resolver answered with [record]'s content, so a change to
  /// [record] has propagated.
  bool matches(DnsRecord record) =>
      consistent &&
      answers.isNotEmpty &&
      answers.values.every(
        (records) => records.any(
          (answer) => answer.canonicalContent == record.canonicalContent,
        ),
      );

  /// Whether every resolver answered and none returned [record]'s content,
  /// so a deletion of [record] has propagated. Other records with the same
  /// name and type may remain.
  bool lacks(DnsRecord record) =>
      failedResolvers.isEmpty &&
      answers.isNotEmpty &&
      answers.values.every(
        (records) => records.every(
          (answer) => answer.canonicalContent != record.canonicalContent,
        ),
      );
}

/// What one DNS-over-HTTPS lookup returned.
class DnsLookupResult {
  /// Creates a lookup result.
  const DnsLookupResult({
    required this.records,
    this.cnames = const <DnsRecord>[],
    this.nxdomain = false,
    this.authenticated = false,
  });

  /// Answers of the queried type.
  final List<DnsRecord> records;

  /// CNAME records the resolver followed before reaching [records].
  final List<DnsRecord> cnames;

  /// Whether the name does not exist (DNS status 3, NXDOMAIN).
  final bool nxdomain;

  /// Whether the resolver validated the answer with DNSSEC (the `AD` flag).
  final bool authenticated;
}
