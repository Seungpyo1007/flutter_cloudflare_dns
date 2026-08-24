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
