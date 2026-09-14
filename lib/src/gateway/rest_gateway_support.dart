import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/dns_record.dart';
import '../models/dns_zone.dart';
import '../validation/dns_record_validator.dart';
import 'cloudflare_dns_gateway.dart';

/// Shared JSON transport for REST-based [CloudflareDnsGateway]s.
abstract class RestCloudflareDnsGateway implements CloudflareDnsGateway {
  /// Creates a gateway that sends requests through [client].
  RestCloudflareDnsGateway({required this.client});

  /// Upper bound on pages read by [fetchAllPages], guarding against a
  /// misbehaving server that never reports its last page.
  static const int maxPages = 1000;

  /// HTTP client used for every request.
  final http.Client client;

  /// Sends a JSON request and buffers the full response.
  Future<http.Response> send(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
  }) {
    final request = http.Request(method, uri)
      ..headers.addAll(<String, String>{
        'accept': 'application/json',
        if (body != null) 'content-type': 'application/json',
        ...?headers,
      });
    if (body != null) request.body = jsonEncode(body);
    return client.send(request).then(http.Response.fromStream);
  }

  /// Decodes [response], throwing [CloudflareDnsException] on failure.
  ///
  /// Returns the `result` value of a Cloudflare-style envelope, or the whole
  /// JSON body when it is not wrapped.
  Object? decode(http.Response response) {
    final decoded = _decodeChecked(response);
    if (decoded is Map && decoded.containsKey('result')) {
      return decoded['result'];
    }
    return decoded;
  }

  /// Reads every page of a list endpoint and concatenates the results.
  ///
  /// [uriForPage] builds the request URI for a 1-based page number. Paging
  /// continues while the envelope's `result_info.total_pages` reports more
  /// pages, so servers that return a bare list are read once. A page whose
  /// result is not a list is returned unchanged for the caller to reject.
  Future<Object?> fetchAllPages(
    Uri Function(int page) uriForPage, {
    Map<String, String>? headers,
  }) async {
    final items = <Object?>[];
    for (var page = 1; page <= maxPages; page++) {
      final decoded = _decodeChecked(
        await send('GET', uriForPage(page), headers: headers),
      );
      final result = decoded is Map && decoded.containsKey('result')
          ? decoded['result']
          : decoded;
      if (result is! List) return result;
      items.addAll(result);
      final resultInfo = decoded is Map ? decoded['result_info'] : null;
      final totalPages = resultInfo is Map
          ? int.tryParse('${resultInfo['total_pages']}')
          : null;
      if (totalPages == null || page >= totalPages || result.isEmpty) break;
    }
    return items;
  }

  Object? _decodeChecked(http.Response response) {
    Object? decoded;
    try {
      decoded = response.body.isEmpty ? null : jsonDecode(response.body);
    } on FormatException {
      throw CloudflareDnsException(
        'The DNS service returned an invalid response.',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw errorFrom(decoded, response.statusCode);
    }
    if (decoded is Map && decoded['success'] == false) {
      throw errorFrom(decoded, response.statusCode);
    }
    return decoded;
  }

  /// Builds a sanitized exception from a decoded error body.
  CloudflareDnsException errorFrom(Object? decoded, int statusCode) {
    String? message;
    String? code;
    if (decoded is Map) {
      final errors = decoded['errors'];
      if (errors is List && errors.isNotEmpty && errors.first is Map) {
        final first = errors.first as Map;
        message = first['message']?.toString();
        code = first['code']?.toString();
      }
      message ??= decoded['message']?.toString();
      code ??= decoded['code']?.toString();
    }
    return CloudflareDnsException(
      message ?? 'DNS request failed with HTTP $statusCode.',
      statusCode: statusCode,
      code: code,
    );
  }

  /// Parses a list of zones.
  List<DnsZone> parseZones(Object? result) {
    if (result is! List) {
      throw const CloudflareDnsException('Expected a list of DNS zones.');
    }
    return result
        .whereType<Map>()
        .map((item) => DnsZone.fromJson(_stringMap(item)))
        .toList(growable: false);
  }

  /// Parses a list of records, skipping unsupported DNS types.
  List<DnsRecord> parseRecords(Object? result) {
    if (result is! List) {
      throw const CloudflareDnsException('Expected a list of DNS records.');
    }
    return result
        .whereType<Map>()
        .where((item) => DnsRecordType.tryParse(item['type']) != null)
        .map((item) => DnsRecord.fromJson(_stringMap(item)))
        .toList(growable: false);
  }

  /// Parses a single record.
  DnsRecord parseRecord(Object? result) {
    if (result is! Map) {
      throw const CloudflareDnsException('Expected a DNS record.');
    }
    return DnsRecord.fromJson(_stringMap(result));
  }

  /// Validates [record] and serializes it as a write request body.
  Map<String, Object?> writeBody(DnsRecord record) {
    DnsRecordValidator.validateOrThrow(record);
    return record.toCloudflareJson();
  }
}

Map<String, Object?> _stringMap(Map<dynamic, dynamic> value) =>
    value.map((key, item) => MapEntry(key.toString(), item));
