import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../models/dns_record.dart';
import '../models/dns_zone.dart';
import '../validation/dns_record_validator.dart';
import 'cloudflare_dns_gateway.dart';

/// Shared JSON transport for REST-based [CloudflareDnsGateway]s.
abstract class RestCloudflareDnsGateway implements CloudflareDnsGateway {
  /// Creates a gateway that sends requests through [client].
  ///
  /// Set [ownsClient] when the gateway created [client], so [close] releases it.
  RestCloudflareDnsGateway({
    required this.client,
    this.ownsClient = false,
    this.requestTimeout = const Duration(seconds: 10),
    this.recordPolicy = const DnsRecordPolicy(),
  });

  /// Plan limits records are validated against before every write. Pass
  /// [DnsRecordPolicy.enterprise] for Enterprise zones.
  final DnsRecordPolicy recordPolicy;

  /// How long one HTTP request may take, including reading the response,
  /// before [send] throws a [CloudflareDnsException] with code `timeout`.
  ///
  /// A timed-out write may still have been applied by the server; reload the
  /// records before retrying it.
  final Duration requestTimeout;

  /// Whether [close] releases [client], because this gateway created it.
  final bool ownsClient;

  /// Closes the HTTP client this gateway created. An injected client is left
  /// open for its owner.
  void close() {
    if (ownsClient) client.close();
  }

  /// Upper bound on pages read by [fetchAllPages], guarding against a
  /// misbehaving server that never reports its last page.
  static const int maxPages = 1000;

  /// HTTP client used for every request.
  final http.Client client;

  /// Retries [send] makes after an HTTP 429 response.
  static const int maxRetries = 3;

  /// Sends a JSON request and buffers the full response.
  ///
  /// HTTP 429 responses are retried up to [maxRetries] times, waiting as long
  /// as `Retry-After` asks (seconds or an HTTP date, at most 60 seconds) or
  /// 1, 2, then 4 seconds. Each attempt is limited to [requestTimeout].
  Future<http.Response> send(
    String method,
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    for (var attempt = 0; ; attempt++) {
      // A sent request cannot be re-sent, so build a new one per attempt.
      final request = http.Request(method, uri)
        ..headers.addAll(<String, String>{
          'accept': 'application/json',
          if (body != null) 'content-type': 'application/json',
          ...?headers,
        });
      if (body != null) request.body = jsonEncode(body);
      final http.Response response;
      try {
        response = await client
            .send(request)
            .then(http.Response.fromStream)
            .timeout(requestTimeout);
      } on TimeoutException {
        throw CloudflareDnsException(
          'The DNS service did not respond within '
          '${requestTimeout.inSeconds} seconds.',
          code: 'timeout',
        );
      }
      if (response.statusCode != 429 || attempt >= maxRetries) return response;
      await Future<void>.delayed(
        retryDelay(response.headers['retry-after'], attempt, DateTime.now()),
      );
    }
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
        .map(_record)
        .toList(growable: false);
  }

  /// Parses a single record.
  DnsRecord parseRecord(Object? result) {
    if (result is! Map) {
      throw const CloudflareDnsException('Expected a DNS record.');
    }
    return _record(result);
  }

  DnsRecord _record(Map<dynamic, dynamic> item) {
    try {
      return DnsRecord.fromJson(_stringMap(item));
    } on FormatException catch (error) {
      throw CloudflareDnsException(
        'The DNS service returned an invalid record: ${error.message}',
        code: 'invalid_record',
      );
    }
  }

  /// Validates every change and builds a Cloudflare batch request body.
  Map<String, Object?> batchBody({
    required Iterable<DnsRecord> posts,
    required Iterable<DnsRecord> patches,
    required Iterable<String> deletes,
  }) {
    final patchList = patches.toList(growable: false);
    if (patchList.any((record) => record.id == null)) {
      throw ArgumentError.value(
        patches,
        'patches',
        'Every patched record needs an id.',
      );
    }
    return <String, Object?>{
      'deletes': <Object?>[
        for (final id in deletes) <String, Object?>{'id': id},
      ],
      'patches': <Object?>[
        for (final record in patchList)
          <String, Object?>{'id': record.id, ...writeBody(record)},
      ],
      'posts': <Object?>[for (final record in posts) writeBody(record)],
    };
  }

  /// Parses a batch response, skipping unsupported DNS types.
  DnsBatchResult parseBatch(Object? result) {
    if (result is! Map) {
      throw const CloudflareDnsException('Expected a DNS batch result.');
    }
    List<DnsRecord> records(String key) =>
        result[key] is List ? parseRecords(result[key]) : const <DnsRecord>[];
    final deletes = result['deletes'];
    return DnsBatchResult(
      posts: records('posts'),
      patches: records('patches'),
      deletes: deletes is List
          ? <String>[
              for (final item in deletes)
                if (item is Map && item['id'] != null) '${item['id']}',
            ]
          : const <String>[],
    );
  }

  /// Validates [record] and serializes it as a write request body.
  Map<String, Object?> writeBody(DnsRecord record) {
    DnsRecordValidator.validateOrThrow(record, policy: recordPolicy);
    return record.toCloudflareJson();
  }
}

/// How long to wait before retry number [attempt] (0-based) after a 429
/// response whose `Retry-After` header is [retryAfter], at [now].
///
/// The header may be delay seconds or an HTTP date (RFC 9110); without a
/// usable value the wait doubles from 1 second. Never more than 60 seconds.
Duration retryDelay(String? retryAfter, int attempt, DateTime now) {
  final value = retryAfter?.trim() ?? '';
  final seconds = int.tryParse(value);
  Duration delay;
  if (seconds != null) {
    delay = Duration(seconds: seconds);
  } else {
    try {
      delay = parseHttpDate(value).difference(now);
    } on FormatException {
      delay = Duration(seconds: 1 << attempt);
    }
  }
  const max = Duration(seconds: 60);
  return delay.isNegative
      ? Duration.zero
      : delay > max
      ? max
      : delay;
}

Map<String, Object?> _stringMap(Map<dynamic, dynamic> value) =>
    value.map((key, item) => MapEntry(key.toString(), item));
