import 'package:http/http.dart' as http;

import '../models/dns_record.dart';
import '../models/dns_zone.dart';
import 'rest_gateway_support.dart';

/// Calls an application-owned backend that holds the Cloudflare token.
///
/// REST contract:
/// `GET /zones`, `GET|POST /dns-records?zoneId=...`, and
/// `PATCH|DELETE /dns-records/{recordId}?zoneId=...`.
///
/// List requests include a 1-based `page` query parameter. A backend that
/// paginates should answer with `{ "result": [...], "result_info":
/// { "total_pages": n } }`; a bare list is treated as the only page.
class ProxyCloudflareGateway extends RestCloudflareDnsGateway {
  /// Creates a safe-by-default proxy gateway.
  ProxyCloudflareGateway({
    required this.baseUri,
    this.headersProvider,
    http.Client? client,
  }) : super(client: client ?? http.Client(), ownsClient: client == null);

  /// Base URI of the application's DNS proxy.
  final Uri baseUri;

  /// Supplies application authentication headers, if required.
  final Future<Map<String, String>> Function()? headersProvider;

  Future<Map<String, String>> _headers() async =>
      await headersProvider?.call() ?? const <String, String>{};

  Uri _uri(String path, [Map<String, String>? query]) => baseUri.replace(
    path: '${baseUri.path.replaceFirst(RegExp(r'/$'), '')}/$path',
    queryParameters: query,
  );

  @override
  Future<List<DnsZone>> listZones() async {
    final headers = await _headers();
    return parseZones(
      await fetchAllPages(
        (page) => _uri('zones', {'page': '$page'}),
        headers: headers,
      ),
    );
  }

  @override
  Future<List<DnsRecord>> listRecords(String zoneId) async {
    final headers = await _headers();
    return parseRecords(
      await fetchAllPages(
        (page) => _uri('dns-records', {'zoneId': zoneId, 'page': '$page'}),
        headers: headers,
      ),
    );
  }

  @override
  Future<DnsRecord> createRecord(String zoneId, DnsRecord record) async {
    final response = await send(
      'POST',
      _uri('dns-records', {'zoneId': zoneId}),
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
      'PATCH',
      _uri('dns-records/$recordId', {'zoneId': zoneId}),
      headers: await _headers(),
      body: writeBody(record),
    );
    return parseRecord(decode(response));
  }

  @override
  Future<void> deleteRecord(String zoneId, String recordId) async {
    final response = await send(
      'DELETE',
      _uri('dns-records/$recordId', {'zoneId': zoneId}),
      headers: await _headers(),
    );
    decode(response);
  }
}
