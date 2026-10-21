import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/dns_health.dart';
import '../models/dns_record.dart';

/// Public DNS diagnostics backed by Cloudflare DNS-over-HTTPS.
class DnsDiagnostics {
  /// Creates a diagnostics client.
  ///
  /// Each lookup fails after [requestTimeout], and at most
  /// [maxConcurrentLookups] lookups run at once, so large zones do not flood
  /// public resolvers.
  DnsDiagnostics({
    http.Client? client,
    Uri? endpoint,
    this.requestTimeout = const Duration(seconds: 10),
    this.maxConcurrentLookups = 8,
  }) : assert(maxConcurrentLookups > 0),
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       endpoint = endpoint ?? Uri.parse('https://cloudflare-dns.com/dns-query');

  /// How long one DNS-over-HTTPS request may take before it fails.
  final Duration requestTimeout;

  /// Lookups [check] and [compareResolvers] run at the same time.
  final int maxConcurrentLookups;

  final http.Client _client;
  final bool _ownsClient;

  /// Closes the HTTP client this instance created. An injected client is left
  /// open for its owner.
  void close() {
    if (_ownsClient) _client.close();
  }

  /// DNS-over-HTTPS JSON endpoint.
  final Uri endpoint;

  /// Resolves [name] for one supported [type].
  Future<List<DnsRecord>> lookup(String name, DnsRecordType type) =>
      _lookupAt(endpoint, name, type);

  /// Public DNS-over-HTTPS JSON resolvers used by [compareResolvers].
  static final Map<String, Uri> publicResolvers = <String, Uri>{
    'Cloudflare': Uri.parse('https://cloudflare-dns.com/dns-query'),
    'Google': Uri.parse('https://dns.google/resolve'),
  };

  /// Looks up every distinct name and type in [records] on each resolver.
  ///
  /// Use it to see whether a change has propagated: a comparison is
  /// [DnsResolverComparison.consistent] only when every resolver answered
  /// with the same records. Defaults to [publicResolvers].
  Future<List<DnsResolverComparison>> compareResolvers(
    Iterable<DnsRecord> records, {
    Map<String, Uri>? resolvers,
  }) async {
    final targets = <String, ({String name, DnsRecordType type})>{
      for (final record in records)
        '${record.name}|${record.type.wireName}': (
          name: record.name,
          type: record.type,
        ),
    };
    final endpoints = resolvers ?? publicResolvers;
    final answers = <String, Map<String, List<DnsRecord>>>{
      for (final key in targets.keys) key: <String, List<DnsRecord>>{},
    };
    final failed = <String, Set<String>>{
      for (final key in targets.keys) key: <String>{},
    };
    await _limited(<Future<void> Function()>[
      for (final target in targets.entries)
        for (final resolver in endpoints.entries)
          () async {
            try {
              answers[target.key]![resolver.key] = await _lookupAt(
                resolver.value,
                target.value.name,
                target.value.type,
              );
            } on Object {
              answers[target.key]![resolver.key] = const <DnsRecord>[];
              failed[target.key]!.add(resolver.key);
            }
          },
    ]);
    return <DnsResolverComparison>[
      for (final target in targets.entries)
        DnsResolverComparison(
          name: target.value.name,
          type: target.value.type,
          // Keep the resolver order of [endpoints] regardless of which
          // lookup finished first.
          answers: <String, List<DnsRecord>>{
            for (final label in endpoints.keys)
              label: answers[target.key]![label] ?? const <DnsRecord>[],
          },
          failedResolvers: failed[target.key]!,
        ),
    ];
  }

  /// Polls [compareResolvers] for [record] until every resolver returns it.
  ///
  /// Emits one comparison per poll, [interval] apart, and closes after the
  /// first one that [DnsResolverComparison.matches] [record], or once
  /// [timeout] has passed, even while a lookup is still running. When the
  /// last comparison does not match, the change has not reached every
  /// resolver yet. Cancelling the subscription stops polling. [record]'s name
  /// must be fully qualified.
  Stream<DnsResolverComparison> watchPropagation(
    DnsRecord record, {
    Duration interval = const Duration(seconds: 15),
    Duration timeout = const Duration(minutes: 10),
    Map<String, Uri>? resolvers,
  }) {
    var closed = false;
    Timer? next;
    Timer? deadline;
    late final StreamController<DnsResolverComparison> controller;

    void finish() {
      if (closed) return;
      closed = true;
      next?.cancel();
      deadline?.cancel();
      controller.close();
    }

    Future<void> poll() async {
      if (closed) return;
      try {
        final comparisons = await compareResolvers(<DnsRecord>[
          record,
        ], resolvers: resolvers);
        if (closed) return;
        final comparison = comparisons.single;
        controller.add(comparison);
        if (comparison.matches(record)) return finish();
      } on Object catch (error, stackTrace) {
        if (closed) return;
        controller.addError(error, stackTrace);
      }
      next = Timer(interval, poll);
    }

    controller = StreamController<DnsResolverComparison>(
      onListen: () {
        // A timer, not a poll count, so a hung lookup cannot hold the stream
        // open past [timeout].
        deadline = Timer(timeout, finish);
        poll();
      },
      onCancel: () {
        closed = true;
        next?.cancel();
        deadline?.cancel();
      },
    );
    return controller.stream;
  }

  /// Runs [tasks] with at most [maxConcurrentLookups] in flight.
  Future<void> _limited(List<Future<void> Function()> tasks) async {
    var index = 0;
    Future<void> worker() async {
      while (index < tasks.length) {
        await tasks[index++]();
      }
    }

    await Future.wait(<Future<void>>[
      for (var i = 0; i < maxConcurrentLookups && i < tasks.length; i++)
        worker(),
    ]);
  }

  Future<List<DnsRecord>> _lookupAt(
    Uri endpoint,
    String name,
    DnsRecordType type,
  ) async {
    final uri = endpoint.replace(
      queryParameters: <String, String>{'name': name, 'type': type.wireName},
    );
    final http.Response response;
    try {
      response = await _client
          .get(
            uri,
            headers: const <String, String>{'accept': 'application/dns-json'},
          )
          .timeout(requestTimeout);
    } on TimeoutException {
      throw DnsLookupException(
        name: name,
        type: type,
        message: 'DNS lookup timed out after ${requestTimeout.inSeconds} s.',
      );
    }
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
  ///
  /// A CNAME at [domain] itself is reported as `cname_flattened` (info) and
  /// not looked up: Cloudflare answers apex CNAMEs with the target's A and
  /// AAAA records, so public DNS never shows the CNAME.
  Future<DnsHealthReport> check(
    String domain, {
    Iterable<DnsRecordType> types = const <DnsRecordType>[
      DnsRecordType.a,
      DnsRecordType.aaaa,
      DnsRecordType.cname,
    ],
    Iterable<DnsRecord> expectedRecords = const <DnsRecord>[],
  }) async {
    final apex = _bareName(domain);
    final flattened = <DnsRecord>[];
    final expected = <DnsRecord>[];
    for (final record in expectedRecords) {
      if (record.type == DnsRecordType.cname &&
          _bareName(record.name) == apex) {
        flattened.add(record);
      } else {
        expected.add(record);
      }
    }
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
    await _limited(<Future<void> Function()>[
      for (final entry in queries.entries)
        () async {
          try {
            answers[entry.key] = await lookup(
              entry.value.name,
              entry.value.type,
            );
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
        },
    ]);

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

    // Info last, so errors and warnings lead in the health card.
    issues.addAll(<DnsIssue>[
      for (final record in flattened)
        DnsIssue(
          code: 'cname_flattened',
          message:
              '${record.name} CNAME is flattened by Cloudflare and answers '
              'with A/AAAA records, so it was not checked.',
          severity: DnsIssueSeverity.info,
          recordName: record.name,
          recordType: record.type,
        ),
    ]);

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

String _bareName(String name) =>
    name.trim().toLowerCase().replaceFirst(RegExp(r'\.$'), '');

DnsRecordType? _typeFromCode(int? code) => switch (code) {
  1 => DnsRecordType.a,
  2 => DnsRecordType.ns,
  5 => DnsRecordType.cname,
  12 => DnsRecordType.ptr,
  15 => DnsRecordType.mx,
  16 => DnsRecordType.txt,
  28 => DnsRecordType.aaaa,
  33 => DnsRecordType.srv,
  64 => DnsRecordType.svcb,
  65 => DnsRecordType.https,
  257 => DnsRecordType.caa,
  _ => null,
};
