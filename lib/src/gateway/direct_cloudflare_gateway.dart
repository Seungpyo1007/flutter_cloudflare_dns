import 'package:http/http.dart' as http;

import '../models/dns_record.dart';
import '../models/dns_zone.dart';
import 'rest_gateway_support.dart';

/// Calls Cloudflare's API directly.
///
/// This is intended for trusted, personal, or internal tools. Distributed apps
/// should use [ProxyCloudflareGateway] so Cloudflare tokens stay on a server.
class DirectCloudflareGateway extends RestCloudflareDnsGateway {
  /// Creates a direct gateway.
  ///
  /// [acknowledgeTokenRisk] must be true. The value returned by
  /// [tokenProvider] is requested per operation, kept only in the local stack,
  /// and is never persisted or logged by this package.
  DirectCloudflareGateway({
    required this.tokenProvider,
    required bool acknowledgeTokenRisk,
    http.Client? client,
    Uri? apiBaseUri,
  }) : apiBaseUri =
           apiBaseUri ?? Uri.parse('https://api.cloudflare.com/client/v4'),
       super(client: client ?? http.Client()) {
    if (!acknowledgeTokenRisk) {
      throw ArgumentError.value(
        acknowledgeTokenRisk,
        'acknowledgeTokenRisk',
        'Direct API access can expose a Cloudflare token in distributed apps. '
            'Use ProxyCloudflareGateway or explicitly acknowledge the risk.',
      );
    }
  }

  /// Supplies a token on demand. Do not return a compile-time secret.
  final Future<String> Function() tokenProvider;

  /// Cloudflare API base URI.
  final Uri apiBaseUri;

  Future<Map<String, String>> _headers() async {
    final token = await tokenProvider();
    if (token.trim().isEmpty) {
      throw ArgumentError.value(
        token,
        'token',
        'Cloudflare token cannot be empty.',
      );
    }
    return <String, String>{'authorization': 'Bearer $token'};
  }

  Uri _uri(String path, [Map<String, String>? query]) => apiBaseUri.replace(
    path: '${apiBaseUri.path.replaceFirst(RegExp(r'/$'), '')}/$path',
    queryParameters: query,
  );

  @override
  Future<List<DnsZone>> listZones() async {
    final response = await send(
      'GET',
      _uri('zones', {'per_page': '50'}),
      headers: await _headers(),
    );
    return parseZones(decode(response));
  }

  @override
  Future<List<DnsRecord>> listRecords(String zoneId) async {
    final response = await send(
      'GET',
      _uri('zones/$zoneId/dns_records', {'per_page': '500'}),
      headers: await _headers(),
    );
    return parseRecords(decode(response));
  }

  @override
  Future<DnsRecord> createRecord(String zoneId, DnsRecord record) async {
    final response = await send(
      'POST',
      _uri('zones/$zoneId/dns_records'),
      headers: await _headers(),
      body: writeBody(record),
    );
    return parseRecord(decode(response));
  }

  @override
  Future<DnsRecord> updateRecord(
    String zoneId,
    String recordId,
    DnsRecord record,
  ) async {
    final response = await send(
      'PUT',
      _uri('zones/$zoneId/dns_records/$recordId'),
      headers: await _headers(),
      body: writeBody(record),
    );
    return parseRecord(decode(response));
  }

  @override
  Future<void> deleteRecord(String zoneId, String recordId) async {
    final response = await send(
      'DELETE',
      _uri('zones/$zoneId/dns_records/$recordId'),
      headers: await _headers(),
    );
    decode(response);
  }
}
