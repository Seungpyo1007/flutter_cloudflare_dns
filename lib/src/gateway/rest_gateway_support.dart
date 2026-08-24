import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/dns_record.dart';
import '../models/dns_zone.dart';
import '../validation/dns_record_validator.dart';
import 'cloudflare_dns_gateway.dart';

abstract class RestCloudflareDnsGateway implements CloudflareDnsGateway {
  RestCloudflareDnsGateway({required this.client});

  final http.Client client;

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

  Object? decode(http.Response response) {
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
    if (decoded is Map && decoded.containsKey('result')) {
      return decoded['result'];
    }
    return decoded;
  }

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

  List<DnsZone> parseZones(Object? result) {
    if (result is! List) {
      throw const CloudflareDnsException('Expected a list of DNS zones.');
    }
    return result
        .whereType<Map>()
        .map((item) => DnsZone.fromJson(_stringMap(item)))
        .toList(growable: false);
  }

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

  DnsRecord parseRecord(Object? result) {
    if (result is! Map) {
      throw const CloudflareDnsException('Expected a DNS record.');
    }
    return DnsRecord.fromJson(_stringMap(result));
  }

  Map<String, Object?> writeBody(DnsRecord record) {
    DnsRecordValidator.validateOrThrow(record);
    return record.toCloudflareJson();
  }
}

Map<String, Object?> _stringMap(Map<dynamic, dynamic> value) =>
    value.map((key, item) => MapEntry(key.toString(), item));
