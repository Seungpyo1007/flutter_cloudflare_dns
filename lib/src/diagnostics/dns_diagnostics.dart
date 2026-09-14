import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/dns_health.dart';
import '../models/dns_record.dart';

/// Public DNS diagnostics backed by Cloudflare DNS-over-HTTPS.
class DnsDiagnostics {
  /// Creates a diagnostics client.
  DnsDiagnostics({http.Client? client, Uri? endpoint})
    : _client = client ?? http.Client(),
      endpoint = endpoint ?? Uri.parse('https://cloudflare-dns.com/dns-query');

  final http.Client _client;

  /// DNS-over-HTTPS JSON endpoint.
  final Uri endpoint;

  /// Resolves [name] for one supported [type].
  Future<List<DnsRecord>> lookup(String name, DnsRecordType type) async {
    final uri = endpoint.replace(
      queryParameters: <String, String>{'name': name, 'type': type.wireName},
    );
    final response = await _client.get(
      uri,
      headers: const <String, String>{'accept': 'application/dns-json'},
    );
    if (response.statusCode != 200) {
      throw DnsLookupException(
        name: name,
        type: type,
        message: 'DNS lookup failed with HTTP ${response.statusCode}.',
      );
    }
    final json = jsonDecode(response.body);
    if (json is! Map) {
      throw DnsLookupException(
        name: name,
        type: type,
        message: 'Invalid DNS response.',
      );
    }
    final status = _asInt(json['Status']) ?? -1;
    if (status != 0) {
      throw DnsLookupException(
        name: name,
        type: type,
        status: status,
        message: status == 3
            ? 'DNS name does not exist.'
            : 'DNS returned status $status.',
      );
    }
    final answers = json['Answer'];
    if (answers is! List) return const <DnsRecord>[];
    return answers
        .whereType<Map>()
        .map((answer) {
          final answerType = _typeFromCode(_asInt(answer['type'])) ?? type;
          return DnsRecord.fromJson(<String, Object?>{
            'name':
                answer['name']?.toString().replaceFirst(RegExp(r'\.$'), '') ??
                name,
            'type': answerType.wireName,
            'content': answer['data']?.toString() ?? '',
            'ttl': _asInt(answer['TTL']) ?? 1,
          });
        })
        .toList(growable: false);
  }

  /// Checks public answers and compares them with optional expected records.
  Future<DnsHealthReport> check(
    String domain, {
    Iterable<DnsRecordType> types = const <DnsRecordType>[
      DnsRecordType.a,
      DnsRecordType.aaaa,
      DnsRecordType.cname,
    ],
    Iterable<DnsRecord> expectedRecords = const <DnsRecord>[],
  }) async {
    final expected = expectedRecords.toList(growable: false);
    final queries = <String, ({String name, DnsRecordType type})>{};
    for (final type in types) {
      queries['$domain|${type.wireName}'] = (name: domain, type: type);
    }
    for (final record in expected) {
      queries['${record.name}|${record.type.wireName}'] = (
        name: record.name,
        type: record.type,
      );
    }

    final answers = <String, List<DnsRecord>>{};
    final issues = <DnsIssue>[];
    await Future.wait(
      queries.entries.map((entry) async {
        try {
          answers[entry.key] = await lookup(entry.value.name, entry.value.type);
        } on DnsLookupException catch (error) {
          answers[entry.key] = const <DnsRecord>[];
          issues.add(
            DnsIssue(
              code: error.status == 3 ? 'nxdomain' : 'lookup_failed',
              message:
                  '${entry.value.name} ${entry.value.type.wireName}: ${error.message}',
              severity: DnsIssueSeverity.error,
              recordName: entry.value.name,
              recordType: entry.value.type,
            ),
          );
        } on Object {
          answers[entry.key] = const <DnsRecord>[];
          issues.add(
            DnsIssue(
              code: 'lookup_failed',
              message:
                  '${entry.value.name} ${entry.value.type.wireName}: lookup failed.',
              severity: DnsIssueSeverity.error,
              recordName: entry.value.name,
              recordType: entry.value.type,
            ),
          );
        }
      }),
    );

    for (final record in expected) {
      final key = '${record.name}|${record.type.wireName}';
      final observed = answers[key] ?? const <DnsRecord>[];
      if (observed.isEmpty) {
        issues.add(
          DnsIssue(
            code: 'missing_record',
            message:
                '${record.name} ${record.type.wireName} is not publicly visible.',
            severity: DnsIssueSeverity.error,
            recordName: record.name,
            recordType: record.type,
          ),
        );
      } else if (!observed.any(
        (answer) =>
            answer.type == record.type &&
            answer.canonicalContent == record.canonicalContent,
      )) {
        issues.add(
          DnsIssue(
            code: 'content_mismatch',
            message:
                '${record.name} ${record.type.wireName} differs from the configured value.',
            recordName: record.name,
            recordType: record.type,
          ),
        );
      }
    }

    return DnsHealthReport(
      domain: domain,
      checkedAt: DateTime.now().toUtc(),
      answers: answers,
      issues: issues,
    );
  }
}

/// Public DNS lookup failure.
class DnsLookupException implements Exception {
  /// Creates a lookup failure.
  const DnsLookupException({
    required this.name,
    required this.type,
    required this.message,
    this.status,
  });

  /// Queried DNS name.
  final String name;

  /// Queried DNS type.
  final DnsRecordType type;

  /// DNS status code, when available.
  final int? status;

  /// Safe error description.
  final String message;

  @override
  String toString() => message;
}

int? _asInt(Object? value) => value is int ? value : int.tryParse('$value');

DnsRecordType? _typeFromCode(int? code) => switch (code) {
  1 => DnsRecordType.a,
  2 => DnsRecordType.ns,
  5 => DnsRecordType.cname,
  15 => DnsRecordType.mx,
  16 => DnsRecordType.txt,
  28 => DnsRecordType.aaaa,
  33 => DnsRecordType.srv,
  257 => DnsRecordType.caa,
  _ => null,
};
