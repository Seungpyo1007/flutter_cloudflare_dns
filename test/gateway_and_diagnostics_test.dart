import 'dart:convert';

import 'package:flutter_cloudflare_dns/flutter_cloudflare_dns.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('DirectCloudflareGateway', () {
    test('requires an explicit direct-token risk acknowledgement', () {
      expect(
        () => DirectCloudflareGateway(
          tokenProvider: () async => 'token',
          acknowledgeTokenRisk: false,
        ),
        throwsArgumentError,
      );
    });

    test('adds bearer auth and maps Cloudflare zones', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{
            'success': true,
            'result': <Object?>[
              <String, Object?>{
                'id': 'zone-1',
                'name': 'example.com',
                'status': 'active',
              },
            ],
          }),
          200,
        );
      });
      final gateway = DirectCloudflareGateway(
        tokenProvider: () async => 'secret-token',
        acknowledgeTokenRisk: true,
        client: client,
      );

      final zones = await gateway.listZones();

      expect(zones.single.name, 'example.com');
      expect(captured.headers['authorization'], 'Bearer secret-token');
      expect(captured.url.path, '/client/v4/zones');
    });

    test('serializes SRV fields for create', () async {
      late Map<String, Object?> body;
      final client = MockClient((request) async {
        body = (jsonDecode(request.body) as Map).cast<String, Object?>();
        return http.Response(
          jsonEncode(<String, Object?>{
            'success': true,
            'result': <String, Object?>{'id': 'srv-1', ...body},
          }),
          200,
        );
      });
      final gateway = DirectCloudflareGateway(
        tokenProvider: () async => 'token',
        acknowledgeTokenRisk: true,
        client: client,
      );
      final record = DnsRecord.srv(
        name: '_minecraft._tcp.example.com',
        priority: 0,
        weight: 0,
        port: 25566,
        target: 'mc.example.com',
      );

      final created = await gateway.createRecord('zone-1', record);

      expect((body['data'] as Map)['port'], 25566);
      expect(created.id, 'srv-1');
      expect(created.target, 'mc.example.com');
    });

    test('reads every page of zones and records', () async {
      final requests = <Uri>[];
      final client = MockClient((request) async {
        requests.add(request.url);
        final page = int.parse(request.url.queryParameters['page']!);
        final isZones = request.url.path.endsWith('/zones');
        return http.Response(
          jsonEncode(<String, Object?>{
            'success': true,
            'result': <Object?>[
              if (isZones)
                <String, Object?>{'id': 'zone-$page', 'name': 'z$page.example'}
              else
                <String, Object?>{
                  'id': 'a-$page',
                  'type': 'A',
                  'name': 'a$page.example.com',
                  'content': '192.0.2.$page',
                },
            ],
            'result_info': <String, Object?>{
              'page': page,
              'total_pages': isZones ? 2 : 3,
            },
          }),
          200,
        );
      });
      final gateway = DirectCloudflareGateway(
        tokenProvider: () async => 'token',
        acknowledgeTokenRisk: true,
        client: client,
      );

      final zones = await gateway.listZones();
      final records = await gateway.listRecords('zone-1');

      expect(zones.map((zone) => zone.id), <String>['zone-1', 'zone-2']);
      expect(records.map((record) => record.id), <String>['a-1', 'a-2', 'a-3']);
      expect(requests, hasLength(5));
      expect(requests.first.queryParameters['per_page'], '50');
      expect(requests.last.queryParameters['per_page'], '500');
    });

    test('serializes MX and CAA fields for create', () async {
      final bodies = <Map<String, Object?>>[];
      final client = MockClient((request) async {
        final body = (jsonDecode(request.body) as Map).cast<String, Object?>();
        bodies.add(body);
        return http.Response(
          jsonEncode(<String, Object?>{
            'success': true,
            'result': <String, Object?>{'id': 'new', ...body},
          }),
          200,
        );
      });
      final gateway = DirectCloudflareGateway(
        tokenProvider: () async => 'token',
        acknowledgeTokenRisk: true,
        client: client,
      );

      final mx = await gateway.createRecord(
        'zone-1',
        DnsRecord.mx(
          name: 'example.com',
          priority: 10,
          mailServer: 'mail.example.com',
          tags: const <String>['team:mail'],
        ),
      );
      final caa = await gateway.createRecord(
        'zone-1',
        DnsRecord.caa(
          name: 'example.com',
          tag: 'issue',
          value: 'letsencrypt.org',
        ),
      );

      expect(bodies.first['priority'], 10);
      expect(bodies.first['content'], 'mail.example.com');
      expect(bodies.first['tags'], <String>['team:mail']);
      expect(bodies.last['data'], <String, Object?>{
        'flags': 0,
        'tag': 'issue',
        'value': 'letsencrypt.org',
      });
      expect(bodies.last.containsKey('tags'), isFalse);
      expect(mx.priority, 10);
      expect(caa.caaValue, 'letsencrypt.org');
    });
  });

  test('ProxyCloudflareGateway follows proxy contract and app auth', () async {
    late http.Request captured;
    final client = MockClient((request) async {
      captured = request;
      return http.Response('[]', 200);
    });
    final gateway = ProxyCloudflareGateway(
      baseUri: Uri.parse('https://backend.example/dns'),
      headersProvider: () async => <String, String>{
        'authorization': 'Bearer app-session',
      },
      client: client,
    );

    expect(await gateway.listRecords('zone-1'), isEmpty);
    expect(captured.url.path, '/dns/dns-records');
    expect(captured.url.queryParameters['zoneId'], 'zone-1');
    expect(captured.url.queryParameters['page'], '1');
    expect(captured.headers['authorization'], 'Bearer app-session');
  });

  test('ProxyCloudflareGateway reads a bare list as a single page', () async {
    var requestCount = 0;
    final client = MockClient((request) async {
      requestCount++;
      return http.Response(
        '[{"id":"zone-1","name":"example.com","status":"active"}]',
        200,
      );
    });
    final gateway = ProxyCloudflareGateway(
      baseUri: Uri.parse('https://backend.example'),
      client: client,
    );

    expect((await gateway.listZones()).single.id, 'zone-1');
    expect(requestCount, 1);
  });

  test('record listing ignores unsupported Cloudflare DNS types', () async {
    final client = MockClient(
      (request) async => http.Response(
        jsonEncode(<String, Object?>{
          'result': <Object?>[
            <String, Object?>{
              'id': 'a-1',
              'type': 'A',
              'name': 'example.com',
              'content': '192.0.2.1',
            },
            <String, Object?>{
              'id': 'ptr-1',
              'type': 'PTR',
              'name': '1.2.0.192.in-addr.arpa',
              'content': 'example.com',
            },
          ],
        }),
        200,
      ),
    );
    final gateway = ProxyCloudflareGateway(
      baseUri: Uri.parse('https://backend.example'),
      client: client,
    );

    final records = await gateway.listRecords('zone-1');

    expect(records, hasLength(1));
    expect(records.single.type, DnsRecordType.a);
  });

  group('DnsDiagnostics', () {
    test('parses public answers and reports a healthy match', () async {
      final client = MockClient((request) async {
        final type = request.url.queryParameters['type'];
        final data = type == 'SRV' ? '0 0 25565 mc.example.com.' : '192.0.2.1';
        return http.Response(
          jsonEncode(<String, Object?>{
            'Status': 0,
            'Answer': <Object?>[
              <String, Object?>{
                'name': '${request.url.queryParameters['name']}.',
                'type': type == 'SRV' ? 33 : 1,
                'TTL': 300,
                'data': data,
              },
            ],
          }),
          200,
        );
      });
      final diagnostics = DnsDiagnostics(client: client);
      final srv = DnsRecord.srv(
        name: '_minecraft._tcp.example.com',
        priority: 0,
        weight: 0,
        port: 25565,
        target: 'mc.example.com',
      );

      final report = await diagnostics.check(
        'example.com',
        types: const <DnsRecordType>[DnsRecordType.a],
        expectedRecords: <DnsRecord>[srv],
      );

      expect(report.isHealthy, isTrue);
      expect(report.answers['example.com|A']!.single.content, '192.0.2.1');
      expect(
        report.answers['_minecraft._tcp.example.com|SRV']!.single.port,
        25565,
      );
    });

    test('reports NXDOMAIN and expected-content mismatch', () async {
      var requestCount = 0;
      final client = MockClient((request) async {
        requestCount++;
        if (request.url.queryParameters['name'] == 'missing.example.com') {
          return http.Response('{"Status":3}', 200);
        }
        return http.Response(
          '{"Status":0,"Answer":[{"name":"example.com.","TTL":60,"data":"192.0.2.99"}]}',
          200,
        );
      });
      final diagnostics = DnsDiagnostics(client: client);
      final report = await diagnostics.check(
        'example.com',
        types: const <DnsRecordType>[],
        expectedRecords: const <DnsRecord>[
          DnsRecord(
            type: DnsRecordType.a,
            name: 'example.com',
            content: '192.0.2.1',
          ),
          DnsRecord(
            type: DnsRecordType.a,
            name: 'missing.example.com',
            content: '192.0.2.2',
          ),
        ],
      );

      expect(requestCount, 2);
      expect(
        report.issues.map((issue) => issue.code),
        contains('content_mismatch'),
      );
      expect(report.issues.map((issue) => issue.code), contains('nxdomain'));
    });

    test('parses MX, CAA, and NS answers and matches them', () async {
      final client = MockClient((request) async {
        final answer = switch (request.url.queryParameters['type']) {
          'MX' => <String, Object?>{'type': 15, 'data': '10 mail.example.com.'},
          'CAA' => <String, Object?>{
            'type': 257,
            'data': '0 issue "letsencrypt.org"',
          },
          _ => <String, Object?>{'type': 2, 'data': 'ns1.example.net.'},
        };
        return http.Response(
          jsonEncode(<String, Object?>{
            'Status': 0,
            'Answer': <Object?>[
              <String, Object?>{'name': 'example.com.', 'TTL': 300, ...answer},
            ],
          }),
          200,
        );
      });
      final diagnostics = DnsDiagnostics(client: client);

      final report = await diagnostics.check(
        'example.com',
        types: const <DnsRecordType>[DnsRecordType.ns],
        expectedRecords: <DnsRecord>[
          DnsRecord.mx(
            name: 'example.com',
            priority: 10,
            mailServer: 'mail.example.com',
          ),
          DnsRecord.caa(
            name: 'example.com',
            tag: 'issue',
            value: 'letsencrypt.org',
          ),
        ],
      );

      expect(report.isHealthy, isTrue);
      final mx = report.answers['example.com|MX']!.single;
      expect(mx.priority, 10);
      expect(mx.content, 'mail.example.com.');
      expect(report.answers['example.com|CAA']!.single.caaTag, 'issue');
      expect(report.answers['example.com|NS']!.single.type, DnsRecordType.ns);
    });
  });
}
