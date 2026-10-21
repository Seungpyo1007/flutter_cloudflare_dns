// Regression tests for the fixes in 0.2.1, one group per issue.
import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cloudflare_dns/flutter_cloudflare_dns.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('split TXT values', () {
    // Shapes returned for s1._domainkey.github.com: Cloudflare keeps the
    // character-strings, Google joins them.
    const cloudflare = '"v=DKIM1; k=rsa; p=MIIBIjAN" "BgkqhkiG9w0BAQEF"';
    const google = 'v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEF';
    const record = DnsRecord(
      type: DnsRecordType.txt,
      name: 's1._domainkey.example.com',
      content: google,
    );

    http.Response txt(String data) => http.Response(
      jsonEncode(<String, Object?>{
        'Status': 0,
        'Answer': <Object?>[
          <String, Object?>{
            'name': 's1._domainkey.example.com.',
            'type': 16,
            'TTL': 300,
            'data': data,
          },
        ],
      }),
      200,
    );

    test('compare as the concatenated value', () {
      const split = DnsRecord(
        type: DnsRecordType.txt,
        name: 's1._domainkey.example.com',
        content: cloudflare,
      );
      expect(split.canonicalContent, google);
      expect(split.canonicalContent, record.canonicalContent);
      expect(
        const DnsRecord(
          type: DnsRecordType.txt,
          name: 'example.com',
          content: r'"say \"hi\"" " there"',
        ).canonicalContent,
        'say "hi" there',
      );
    });

    test('match across resolvers and in health checks', () async {
      final client = MockClient(
        (request) async =>
            txt(request.url.host == 'dns.google' ? google : '"$google"'),
      );
      final cfSplit = MockClient((request) async => txt(cloudflare));
      final diagnostics = DnsDiagnostics(client: client);

      final comparison = (await diagnostics.compareResolvers(<DnsRecord>[
        record,
      ])).single;
      expect(comparison.consistent, isTrue);
      expect(comparison.matches(record), isTrue);

      final report = await DnsDiagnostics(client: cfSplit).check(
        'example.com',
        types: const <DnsRecordType>[],
        expectedRecords: const <DnsRecord>[record],
      );
      expect(report.issues, isEmpty);
    });
  });

  group('timeouts', () {
    // A client whose responses never arrive.
    MockClient hanging() =>
        MockClient((request) => Completer<http.Response>().future);

    test('fail a DoH lookup after requestTimeout', () {
      fakeAsync((async) {
        Object? error;
        DnsDiagnostics(
          client: hanging(),
          requestTimeout: const Duration(seconds: 2),
        ).lookup('example.com', DnsRecordType.a).catchError((Object e) {
          error = e;
          return const <DnsRecord>[];
        });
        async.elapse(const Duration(seconds: 3));
        expect(error, isA<DnsLookupException>());
        expect('$error', contains('timed out'));
      });
    });

    test('fail a gateway request after requestTimeout', () {
      fakeAsync((async) {
        Object? error;
        ProxyCloudflareGateway(
          baseUri: Uri.parse('https://api.example.com/dns'),
          client: hanging(),
          requestTimeout: const Duration(seconds: 2),
        ).listZones().catchError((Object e) {
          error = e;
          return const <DnsZone>[];
        });
        async.elapse(const Duration(seconds: 3));
        expect(error, isA<CloudflareDnsException>());
        expect((error! as CloudflareDnsException).code, 'timeout');
      });
    });

    test('close watchPropagation at the deadline despite a hung lookup', () {
      fakeAsync((async) {
        var done = false;
        DnsDiagnostics(
              client: hanging(),
              requestTimeout: const Duration(hours: 1),
            )
            .watchPropagation(
              const DnsRecord(
                type: DnsRecordType.a,
                name: 'www.example.com',
                content: '192.0.2.1',
              ),
              interval: const Duration(seconds: 1),
              timeout: const Duration(seconds: 5),
            )
            .listen((_) {}, onDone: () => done = true);
        async.elapse(const Duration(seconds: 4));
        expect(done, isFalse);
        async.elapse(const Duration(seconds: 2));
        expect(done, isTrue);
      });
    });
  });

  group('case', () {
    DnsRecord txt(String content) => DnsRecord(
      type: DnsRecordType.txt,
      name: 'example.com',
      content: content,
    );

    test('TXT values keep their case', () {
      expect(
        txt('Token=AbC').canonicalContent,
        isNot(txt('token=abc').canonicalContent),
      );
    });

    test('host names and CA domains ignore case and the trailing dot', () {
      expect(
        const DnsRecord(
          type: DnsRecordType.cname,
          name: 'www.example.com',
          content: 'Target.Example.NET.',
        ).canonicalContent,
        'target.example.net',
      );
      expect(
        DnsRecord.caa(
          name: 'example.com',
          tag: 'issue',
          value: 'LetsEncrypt.org',
        ).canonicalContent,
        '0 issue letsencrypt.org',
      );
      expect(
        DnsRecord.caa(
          name: 'example.com',
          tag: 'iodef',
          value: 'mailto:Security@example.com',
        ).canonicalContent,
        '0 iodef mailto:Security@example.com',
      );
    });

    test('IPv6 addresses compare by value', () {
      DnsRecord aaaa(String content) => DnsRecord(
        type: DnsRecordType.aaaa,
        name: 'example.com',
        content: content,
      );
      expect(
        aaaa('2001:DB8::1').canonicalContent,
        aaaa('2001:0db8:0:0:0:0:0:1').canonicalContent,
      );
    });
  });

  group('wildcards', () {
    test('a leading * label is a valid name', () {
      for (final type in <DnsRecordType>[DnsRecordType.a, DnsRecordType.txt]) {
        expect(
          DnsRecordValidator.validate(
            DnsRecord(
              type: type,
              name: '*.example.com',
              content: type == DnsRecordType.a ? '192.0.2.1' : 'hello',
            ),
          ),
          isEmpty,
        );
      }
      expect(
        DnsRecordValidator.validate(
          const DnsRecord(
            type: DnsRecordType.cname,
            name: '*.dev.example.com',
            content: 'dev.example.net',
          ),
        ),
        isEmpty,
      );
    });

    test('* elsewhere is not', () {
      for (final name in <String>['a.*.example.com', '**.example.com']) {
        expect(
          DnsRecordValidator.validate(
            DnsRecord(type: DnsRecordType.a, name: name, content: '192.0.2.1'),
          ).map((issue) => issue.code),
          contains('invalid_name'),
        );
      }
    });

    test('zone files import wildcard records', () {
      final result = DnsZoneFile.parse(
        '* 300 IN A 192.0.2.1\n*.dev 300 IN CNAME dev.example.net.\n',
        origin: 'example.com',
      );
      expect(result.issues, isEmpty);
      expect(result.records.map((r) => r.name), <String>[
        '*.example.com',
        '*.dev.example.com',
      ]);
      expect(result.records.expand(DnsRecordValidator.validate), isEmpty);
    });
  });

  test('writes always send tags so PATCH clears them', () async {
    final bodies = <Map<String, Object?>>[];
    final gateway = ProxyCloudflareGateway(
      baseUri: Uri.parse('https://api.example.com/dns'),
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, Object?>;
        bodies.add(body);
        return http.Response(
          jsonEncode(<String, Object?>{'id': 'r1', ...body}),
          200,
        );
      }),
    );
    await gateway.updateRecord(
      'zone-1',
      'r1',
      const DnsRecord(
        type: DnsRecordType.a,
        name: 'example.com',
        content: '192.0.2.1',
      ),
    );
    expect(bodies.single['tags'], <Object?>[]);
  });

  group('lookup concurrency', () {
    test(
      'check and compareResolvers keep at most 8 lookups in flight',
      () async {
        var inFlight = 0;
        var peak = 0;
        final client = MockClient((request) async {
          inFlight++;
          if (inFlight > peak) peak = inFlight;
          await Future<void>.delayed(const Duration(milliseconds: 2));
          inFlight--;
          return http.Response(
            jsonEncode(<String, Object?>{'Status': 0, 'Answer': <Object?>[]}),
            200,
          );
        });
        final diagnostics = DnsDiagnostics(client: client);
        final records = <DnsRecord>[
          for (var i = 0; i < 40; i++)
            DnsRecord(
              type: DnsRecordType.a,
              name: 'host$i.example.com',
              content: '192.0.2.1',
            ),
        ];

        final report = await diagnostics.check(
          'example.com',
          types: const <DnsRecordType>[],
          expectedRecords: records,
        );
        expect(report.issues, hasLength(40));
        expect(peak, 8);

        peak = 0;
        final comparisons = await diagnostics.compareResolvers(records);
        expect(comparisons, hasLength(40));
        expect(comparisons.first.answers.keys, <String>[
          'Cloudflare',
          'Google',
        ]);
        expect(peak, 8);
      },
    );

    testWidgets('the dashboard health check is capped', (tester) async {
      final diagnostics = RecordingDiagnostics();
      await tester.pumpWidget(
        _app(
          CloudflareDnsDashboard(
            gateway: MemoryGateway(<DnsRecord>[
              for (var i = 0; i < 150; i++)
                DnsRecord(
                  id: 'r$i',
                  type: DnsRecordType.a,
                  name: 'host$i.example.com',
                  content: '192.0.2.1',
                  proxied: false,
                ),
              const DnsRecord(
                id: 'apex',
                type: DnsRecordType.a,
                name: 'example.com',
                content: '192.0.2.1',
                proxied: false,
              ),
            ]),
            diagnostics: diagnostics,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(diagnostics.checked, hasLength(100));
      expect(diagnostics.checked.first.name, 'example.com');
      expect(find.textContaining('Checked 100 of 151'), findsOneWidget);
    });
  });

  testWidgets('the zone picker scrolls and searches many zones', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        CloudflareDnsDashboard(
          gateway: MemoryGateway(const <DnsRecord>[], zoneCount: 40),
          diagnostics: RecordingDiagnostics(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('zone0.example').first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Choose a zone'), findsOneWidget);

    await tester.enterText(
      find.descendant(
        of: find.widgetWithText(SearchBar, 'Search zones'),
        matching: find.byType(TextField),
      ),
      'zone39',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('zone39.example').last);
    await tester.pumpAndSettle();
    expect(find.text('zone39.example'), findsWidgets);
    expect(find.text('Choose a zone'), findsNothing);
  });

  test('IP addresses are parsed, not pattern matched', () {
    List<String> codes(DnsRecordType type, String content) =>
        DnsRecordValidator.validate(
          DnsRecord(type: type, name: 'example.com', content: content),
        ).map((issue) => issue.code).toList();

    for (final bad in <String>['+1.2.3.4', '01.2.3.4', '256.1.1.1', '1.2.3']) {
      expect(
        codes(DnsRecordType.a, bad),
        contains('invalid_ipv4'),
        reason: bad,
      );
    }
    for (final bad in <String>[
      ':::::',
      '1:2:3:4:5:6:7:8:9',
      '1::2::3',
      'fe80::1%en0',
    ]) {
      expect(
        codes(DnsRecordType.aaaa, bad),
        contains('invalid_ipv6'),
        reason: bad,
      );
    }
    expect(codes(DnsRecordType.a, ' 192.0.2.1 '), isEmpty);
    for (final good in <String>['::ffff:1.2.3.4', '2001:DB8::1', '::1']) {
      expect(codes(DnsRecordType.aaaa, good), isEmpty, reason: good);
    }
  });

  group('zone file TXT bytes', () {
    test('exports split at 255 UTF-8 bytes, never inside a character', () {
      final value = '가' * 200; // 600 bytes
      final text = DnsZoneFile.encode(<DnsRecord>[
        DnsRecord(type: DnsRecordType.txt, name: 'example.com', content: value),
      ], origin: 'example.com');
      final strings = RegExp(
        r'"([^"]*)"',
      ).allMatches(text).map((m) => m[1]!).toList();
      expect(strings, hasLength(3));
      for (final chunk in strings) {
        expect(utf8.encode(chunk).length, lessThanOrEqualTo(255));
      }

      final parsed = DnsZoneFile.parse(text, origin: 'example.com');
      expect(parsed.records.single.content, value);
    });

    test(r'\DDD escapes decode as UTF-8 bytes', () {
      final parsed = DnsZoneFile.parse(
        r'@ 300 IN TXT "smile \240\159\152\128 \034ok\034"',
        origin: 'example.com',
      );
      expect(parsed.records.single.content, 'smile 😀 "ok"');
    });
  });

  group('apex CNAME', () {
    test('is reported as flattened, not looked up', () async {
      final queried = <String>[];
      final diagnostics = DnsDiagnostics(
        client: MockClient((request) async {
          queried.add(request.url.queryParameters['type']!);
          return http.Response(
            jsonEncode(<String, Object?>{'Status': 0, 'Answer': <Object?>[]}),
            200,
          );
        }),
      );
      final report = await diagnostics.check(
        'example.com',
        types: const <DnsRecordType>[],
        expectedRecords: const <DnsRecord>[
          DnsRecord(
            type: DnsRecordType.cname,
            name: 'example.com',
            content: 'site.pages.dev',
          ),
        ],
      );
      expect(queried, isEmpty);
      expect(report.issues.single.code, 'cname_flattened');
      expect(report.issues.single.severity, DnsIssueSeverity.info);
      expect(report.isHealthy, isTrue);
    });

    testWidgets('is not tracked for propagation after a save', (tester) async {
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final diagnostics = RecordingDiagnostics();
      await tester.pumpWidget(
        _app(
          CloudflareDnsDashboard(
            gateway: MemoryGateway(const <DnsRecord>[
              DnsRecord(
                id: 'apex',
                type: DnsRecordType.cname,
                name: 'example.com',
                content: 'old.pages.dev',
                proxied: false,
              ),
            ]),
            diagnostics: diagnostics,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('old.pages.dev'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'old.pages.dev'),
        'new.pages.dev',
      );
      await tester.ensureVisible(find.text('Save record'));
      await tester.tap(find.text('Save record'));
      await tester.pumpAndSettle();

      expect(find.text('new.pages.dev'), findsOneWidget);
      expect(find.text('Propagating'), findsNothing);
      expect(diagnostics.comparisons, 0);
    });
  });

  group('large zones', () {
    final records = <DnsRecord>[
      for (var i = 0; i < 3000; i++)
        DnsRecord(
          id: 'r$i',
          type: DnsRecordType.a,
          name: 'host$i.example.com',
          content: '192.0.2.${i % 250}',
          proxied: true,
        ),
    ];

    testWidgets('DnsRecordList builds only visible tiles', (tester) async {
      await tester.pumpWidget(
        _app(SizedBox(height: 600, child: DnsRecordList(records: records))),
      );
      expect(find.text('host0.example.com'), findsOneWidget);
      expect(
        find.text('host2999.example.com', skipOffstage: false),
        findsNothing,
      );

      await tester.pumpWidget(
        _app(
          CustomScrollView(
            slivers: <Widget>[DnsRecordList.sliver(records: records)],
          ),
        ),
      );
      expect(find.text('host0.example.com'), findsOneWidget);
      expect(
        find.text('host2999.example.com', skipOffstage: false),
        findsNothing,
      );
    });

    testWidgets('the dashboard list is lazy and search is debounced', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          CloudflareDnsDashboard(
            gateway: MemoryGateway(records),
            diagnostics: RecordingDiagnostics(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('host2999.example.com', skipOffstage: false),
        findsNothing,
      );

      List<DnsRecord> visible() => tester
          .widget<DnsRecordList>(
            find.byType(DnsRecordList, skipOffstage: false),
          )
          .records;
      await tester.enterText(
        find.descendant(
          of: find.byType(SearchBar),
          matching: find.byType(TextField),
        ),
        'host2999.',
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(visible(), hasLength(3000));
      await tester.pump(const Duration(milliseconds: 200));
      expect(visible().single.id, 'r2999');
    });
  });

  group('lenient record JSON', () {
    test('accepts booleans and numbers sent as strings', () {
      final record = DnsRecord.fromJson(<String, Object?>{
        'type': 'A',
        'name': 'example.com',
        'content': '192.0.2.1',
        'ttl': '300',
        'proxied': 'true',
      });
      expect(record.proxied, isTrue);
      expect(record.ttl, 300);
      expect(
        DnsRecord.fromJson(<String, Object?>{
          'type': 'MX',
          'name': 'example.com',
          'content': 'mail.example.com',
          'priority': 10.0,
          'proxied': 'FALSE',
        }).priority,
        10,
      );
    });

    test('rejects other values with a sanitized gateway error', () async {
      expect(
        () => DnsRecord.fromJson(<String, Object?>{
          'type': 'A',
          'name': 'example.com',
          'content': '192.0.2.1',
          'proxied': 'yes',
        }),
        throwsFormatException,
      );

      final gateway = ProxyCloudflareGateway(
        baseUri: Uri.parse('https://api.example.com/dns'),
        client: MockClient(
          (request) async => http.Response(
            jsonEncode(<Object?>[
              <String, Object?>{
                'id': 'r1',
                'type': 'A',
                'name': 'example.com',
                'content': '192.0.2.1',
                'proxied': <String, Object?>{},
              },
            ]),
            200,
          ),
        ),
      );
      await expectLater(
        gateway.listRecords('zone-1'),
        throwsA(
          isA<CloudflareDnsException>().having(
            (e) => e.code,
            'code',
            'invalid_record',
          ),
        ),
      );
    });
  });
}

Widget _app(Widget child) => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  home: Scaffold(body: child),
);

/// Gateway over an in-memory record list, with [zoneCount] zones named
/// `zone0.example`, ... or a single `example.com`.
class MemoryGateway implements CloudflareDnsGateway {
  MemoryGateway(List<DnsRecord> records, {this.zoneCount = 0})
    : records = List<DnsRecord>.of(records);

  final List<DnsRecord> records;
  final int zoneCount;

  @override
  Future<List<DnsZone>> listZones() async => zoneCount == 0
      ? const <DnsZone>[DnsZone(id: 'zone-1', name: 'example.com')]
      : <DnsZone>[
          for (var i = 0; i < zoneCount; i++)
            DnsZone(id: 'zone-$i', name: 'zone$i.example'),
        ];

  @override
  Future<List<DnsRecord>> listRecords(String zoneId) async =>
      List<DnsRecord>.of(records);

  @override
  Future<DnsRecord> createRecord(String zoneId, DnsRecord record) async {
    final created = record.copyWith(id: 'new-${records.length}');
    records.add(created);
    return created;
  }

  @override
  Future<DnsRecord> updateRecord(
    String zoneId,
    String recordId,
    DnsRecord record,
  ) async {
    final updated = record.copyWith(id: recordId);
    final index = records.indexWhere((r) => r.id == recordId);
    records[index] = updated;
    return updated;
  }

  @override
  Future<void> deleteRecord(String zoneId, String recordId) async =>
      records.removeWhere((r) => r.id == recordId);
}

/// Diagnostics that answer instantly and record what they were asked.
class RecordingDiagnostics extends DnsDiagnostics {
  List<DnsRecord> checked = const <DnsRecord>[];
  var comparisons = 0;

  @override
  Future<DnsHealthReport> check(
    String domain, {
    Iterable<DnsRecordType> types = const <DnsRecordType>[],
    Iterable<DnsRecord> expectedRecords = const <DnsRecord>[],
  }) async {
    checked = expectedRecords.toList();
    return DnsHealthReport(
      domain: domain,
      checkedAt: DateTime.utc(2026),
      answers: const <String, List<DnsRecord>>{},
      issues: const <DnsIssue>[],
    );
  }

  @override
  Future<List<DnsResolverComparison>> compareResolvers(
    Iterable<DnsRecord> records, {
    Map<String, Uri>? resolvers,
  }) async {
    comparisons++;
    return const <DnsResolverComparison>[];
  }
}
