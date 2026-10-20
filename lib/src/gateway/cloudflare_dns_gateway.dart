import '../models/dns_record.dart';
import '../models/dns_zone.dart';

/// Read/write contract used by the dashboard and custom applications.
abstract interface class CloudflareDnsGateway {
  /// Lists zones available to the authenticated caller.
  Future<List<DnsZone>> listZones();

  /// Lists supported DNS records for [zoneId].
  Future<List<DnsRecord>> listRecords(String zoneId);

  /// Creates [record] in [zoneId].
  Future<DnsRecord> createRecord(String zoneId, DnsRecord record);

  /// Replaces [recordId] with [record] in [zoneId].
  Future<DnsRecord> updateRecord(
    String zoneId,
    String recordId,
    DnsRecord record,
  );

  /// Deletes [recordId] from [zoneId].
  Future<void> deleteRecord(String zoneId, String recordId);
}

/// A gateway that can apply several record changes in one atomic request.
///
/// Optional, so existing [CloudflareDnsGateway] implementations keep working.
/// Check for it with `gateway is BatchCapableGateway`.
abstract interface class BatchCapableGateway implements CloudflareDnsGateway {
  /// Deletes, updates, then creates records in [zoneId] in one request.
  ///
  /// Either every change is applied or none is. Records in [patches] must
  /// have an [DnsRecord.id]; [deletes] are record ids. Cloudflare limits how
  /// many changes one batch may hold, depending on the plan.
  Future<DnsBatchResult> batch(
    String zoneId, {
    Iterable<DnsRecord> posts,
    Iterable<DnsRecord> patches,
    Iterable<String> deletes,
  });
}

/// Records returned by [BatchCapableGateway.batch].
class DnsBatchResult {
  /// Creates a batch result.
  const DnsBatchResult({
    this.posts = const <DnsRecord>[],
    this.patches = const <DnsRecord>[],
    this.deletes = const <String>[],
  });

  /// Created records, with their new ids.
  final List<DnsRecord> posts;

  /// Updated records.
  final List<DnsRecord> patches;

  /// Ids of deleted records.
  final List<String> deletes;
}

/// A sanitized error returned by a gateway.
class CloudflareDnsException implements Exception {
  /// Creates a gateway error.
  const CloudflareDnsException(this.message, {this.statusCode, this.code});

  /// Safe error message. Tokens and request headers are never included.
  final String message;

  /// HTTP response status, if available.
  final int? statusCode;

  /// Provider error code, if available.
  final String? code;

  @override
  String toString() => message;
}
