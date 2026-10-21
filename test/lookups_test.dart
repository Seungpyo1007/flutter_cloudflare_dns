// DoH answer filtering, NXDOMAIN, deletion tracking, DNSSEC, and gateway
// retries and policies (0.3.0).
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_cloudflare_dns/flutter_cloudflare_dns.dart';
import 'package:flutter_cloudflare_dns/src/gateway/rest_gateway_support.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _doh({
  int status = 0,
  bool ad = false,
  List<Map<String, Object?>> answers = const <Map<String, Object?>>[],
}) => http.Response(
  jsonEncode(<String, Object?>{
    'Status': status,
    'AD': ad,
    if (answers.isNotEmpty) 'Answer': answers,
  }),
  200,
);

const _www = DnsRecord(
  type: DnsRecordType.a,
  name: 'www.example.com',
  content: '192.0.2.1',
);

void main() {
  group('answer types', () {
    test(
      'keeps answers of the queried type and the CNAME chain apart',
      () async {
        final diagnostics = DnsDiagnostics(
          client: MockClient(
            (_) async => _doh(
              answers: <Map<String, Object?>>[
                <String, Object?>{
                  'name': 'www.example.com.',
                  'type': 5,
                  'data': 'edge.example.net.',
                },
                <String, Object?>{
                  'name': 'edge.example.net.',
                  'type': 1,
                  'data': '192.0.2.1',
                },
                // RRSIG and DNAME are not supported types and are dropped.
                <String, Object?>{
                  'name': 'edge.example.net.',
                  'type': 46,
                  'data': 'A 13 3 300 ...',
                },
                <String, Object?>{
                  'name': 'example.com.',
                  'type': 39,
                  'data': 'example.net.',
                },
              ],
            ),
          ),
        );
        final result = await diagnostics.resolve(
          'www.example.com',
          DnsRecordType.a,
        );
        expect(result.records.map((r) => r.content), <String>['192.0.2.1']);
        expect(result.cnames.single.content, 'edge.example.net.');
        expect(
          await diagnostics.lookup('www.example.com', DnsRecordType.a),
          hasLength(1),
        );

        final comparison = (await diagnostics.compareResolvers(
          const <DnsRecord>[_www],
        )).single;
        expect(comparison.cnames['Cloudflare'], hasLength(1));
        expect(comparison.matches(_www), isTrue);
      },
    );
  });

  group('NXDOMAIN', () {
    test('is an answer in compareResolvers, not a failure', () async {
      final diagnostics = DnsDiagnostics(
        client: MockClient((_) async => _doh(status: 3)),
      );
      final comparison = (await diagnostics.compareResolvers(const <DnsRecord>[
        _www,
      ])).single;
      expect(comparison.failedResolvers, isEmpty);
      expect(comparison.nxdomainResolvers, <String>{'Cloudflare', 'Google'});
      expect(comparison.consistent, isTrue);
      expect(comparison.lacks(_www), isTrue);
      expect(comparison.matches(_www), isFalse);
    });

    test('lookup still throws with status 3', () async {
      final diagnostics = DnsDiagnostics(
        client: MockClient((_) async => _doh(status: 3)),
      );
      await expectLater(
        diagnostics.lookup('gone.example.com', DnsRecordType.a),
        throwsA(isA<DnsLookupException>().having((e) => e.status, 'status', 3)),
      );
      final result = await diagnostics.resolve(
        'gone.example.com',
        DnsRecordType.a,
      );
      expect(result.nxdomain, isTrue);
    });

    test('lacks is false while one resolver still answers', () {
      const comparison = DnsResolverComparison(
        name: 'www.example.com',
        type: DnsRecordType.a,
        answers: <String, List<DnsRecord>>{
          'Cloudflare': <DnsRecord>[],
          'Google': <DnsRecord>[_www],
        },
      );
      expect(comparison.lacks(_www), isFalse);
      const failed = DnsResolverComparison(
        name: 'www.example.com',
        type: DnsRecordType.a,
        answers: <String, List<DnsRecord>>{
          'Cloudflare': <DnsRecord>[],
          'Google': <DnsRecord>[],
        },
        failedResolvers: <String>{'Google'},
      );
      expect(failed.lacks(_www), isFalse);
    });
  });

  group('watchPropagation removal', () {
    test('closes once no resolver returns the deleted record', () {
      fakeAsync((async) {
        var polls = 0;
        final diagnostics = DnsDiagnostics(
          client: MockClient((request) async {
            // Google drops the record from the third request on.
            if (request.url.host == 'dns.google') polls++;
            final gone = request.url.host == 'cloudflare-dns.com' || polls > 2;
            return gone
                ? _doh(status: 3)
                : _doh(
                    answers: <Map<String, Object?>>[
                      <String, Object?>{
                        'name': 'www.example.com.',
                        'type': 1,
                        'data': '192.0.2.1',
                      },
                    ],
                  );
          }),
        );
        final seen = <bool>[];
        var done = false;
        diagnostics
            .watchPropagation(
              _www,
              interval: const Duration(seconds: 1),
              removal: true,
            )
            .listen((c) => seen.add(c.lacks(_www)), onDone: () => done = true);
        async.elapse(const Duration(seconds: 5));
        expect(seen, <bool>[false, false, true]);
        expect(done, isTrue);
      });
    });
  });

  group('DNSSEC', () {
    test('reports whether every lookup was validated', () async {
      Future<DnsHealthReport> check(bool Function(Uri) ad) => DnsDiagnostics(
        client: MockClient(
          (request) async => _doh(
            ad: ad(request.url),
            answers: <Map<String, Object?>>[
              <String, Object?>{
                'name': 'example.com.',
                'type': 1,
                'data': '192.0.2.1',
              },
            ],
          ),
        ),
      ).check('example.com', types: const <DnsRecordType>[DnsRecordType.a]);

      expect((await check((_) => true)).dnssecValidated, isTrue);
      expect((await check((_) => false)).dnssecValidated, isFalse);
      final failing = await DnsDiagnostics(
        client: MockClient((_) async => http.Response('', 500)),
      ).check('example.com', types: const <DnsRecordType>[DnsRecordType.a]);
      expect(failing.dnssecValidated, isNull);
    });
  });

  group('Retry-After', () {
    final now = DateTime.utc(2026, 10, 21, 12);

    test('reads delay seconds and HTTP dates, capped at 60 seconds', () {
      expect(retryDelay('5', 0, now), const Duration(seconds: 5));
      expect(
        retryDelay('Wed, 21 Oct 2026 12:00:07 GMT', 0, now),
        const Duration(seconds: 7),
      );
      expect(
        retryDelay('Wed, 21 Oct 2026 11:00:00 GMT', 0, now),
        Duration.zero,
      );
      expect(retryDelay('600', 0, now), const Duration(seconds: 60));
      expect(retryDelay(null, 2, now), const Duration(seconds: 4));
      expect(retryDelay('soon', 1, now), const Duration(seconds: 2));
    });
  });

  group('gateway record policy', () {
    test('Enterprise policy lets 30-second TTLs through', () async {
      final bodies = <Object?>[];
      final client = MockClient((request) async {
        bodies.add(jsonDecode(request.body));
        return http.Response(
          jsonEncode(<String, Object?>{
            'success': true,
            'result': <String, Object?>{
              'id': 'r1',
              'type': 'A',
              'name': 'example.com',
              'content': '192.0.2.1',
              'ttl': 30,
            },
          }),
          200,
        );
      });
      final record = _www.copyWith(ttl: 30);
      final standard = ProxyCloudflareGateway(
        baseUri: Uri.parse('https://api.example.com'),
        client: client,
      );
      await expectLater(
        standard.createRecord('zone-1', record),
        throwsA(isA<DnsValidationException>()),
      );
      final enterprise = ProxyCloudflareGateway(
        baseUri: Uri.parse('https://api.example.com'),
        client: client,
        recordPolicy: DnsRecordPolicy.enterprise,
      );
      expect((await enterprise.createRecord('zone-1', record)).ttl, 30);
      expect(bodies, hasLength(1));
    });
  });
}
