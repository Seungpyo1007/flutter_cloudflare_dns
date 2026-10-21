import 'package:flutter_cloudflare_dns/flutter_cloudflare_dns.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DnsRecord', () {
    test('parses and serializes an SRV record', () {
      final record = DnsRecord.fromJson(<String, Object?>{
        'id': 'record-1',
        'type': 'SRV',
        'name': '_minecraft._tcp.example.com',
        'ttl': 120,
        'data': <String, Object?>{
          'priority': 0,
          'weight': 5,
          'port': 25566,
          'target': 'mc.example.com',
        },
      });

      expect(record.type, DnsRecordType.srv);
      expect(record.port, 25566);
      expect(record.canonicalContent, '0 5 25566 mc.example.com');
      expect(record.toCloudflareJson()['data'], <String, Object?>{
        'priority': 0,
        'weight': 5,
        'port': 25566,
        'target': 'mc.example.com',
      });
    });

    test('parses DoH SRV content', () {
      final record = DnsRecord.fromJson(<String, Object?>{
        'type': 'SRV',
        'name': '_minecraft._tcp.example.com',
        'content': '0 0 25565 mc.example.com.',
      });

      expect(record.priority, 0);
      expect(record.weight, 0);
      expect(record.port, 25565);
      expect(record.target, 'mc.example.com.');
      expect(record.canonicalContent, '0 0 25565 mc.example.com');
    });

    test('round trips A, AAAA, CNAME, and TXT records', () {
      for (final record in <DnsRecord>[
        const DnsRecord(
          type: DnsRecordType.a,
          name: 'a.example.com',
          content: '192.0.2.1',
        ),
        const DnsRecord(
          type: DnsRecordType.aaaa,
          name: 'v6.example.com',
          content: '2001:db8::1',
        ),
        const DnsRecord(
          type: DnsRecordType.cname,
          name: 'www.example.com',
          content: 'example.com',
        ),
        const DnsRecord(
          type: DnsRecordType.txt,
          name: 'example.com',
          content: 'verify=ok',
        ),
      ]) {
        final parsed = DnsRecord.fromJson(record.toCloudflareJson());
        expect(parsed.type, record.type);
        expect(parsed.name, record.name);
        expect(parsed.content, record.content);
      }
    });

    test('normalizes quoted TXT answers', () {
      const configured = DnsRecord(
        type: DnsRecordType.txt,
        name: 'example.com',
        content: 'google-site-verification=value',
      );
      const observed = DnsRecord(
        type: DnsRecordType.txt,
        name: 'example.com',
        content: '"google-site-verification=value"',
      );

      expect(observed.canonicalContent, configured.canonicalContent);
    });

    test('parses MX from the Cloudflare API and from DoH', () {
      final api = DnsRecord.fromJson(<String, Object?>{
        'type': 'MX',
        'name': 'example.com',
        'content': 'mail.example.com',
        'priority': 10,
      });
      final doh = DnsRecord.fromJson(<String, Object?>{
        'type': 'MX',
        'name': 'example.com',
        'content': '10 mail.example.com.',
      });

      expect(api.priority, 10);
      expect(api.content, 'mail.example.com');
      expect(doh.priority, 10);
      expect(doh.canonicalContent, api.canonicalContent);
      expect(api.toCloudflareJson(), <String, Object?>{
        'type': 'MX',
        'name': 'example.com',
        'ttl': 1,
        'tags': <String>[],
        'content': 'mail.example.com',
        'priority': 10,
      });
    });

    test('parses CAA from the Cloudflare API and from DoH', () {
      final api = DnsRecord.fromJson(<String, Object?>{
        'type': 'CAA',
        'name': 'example.com',
        'content': '0 issue "letsencrypt.org"',
        'data': <String, Object?>{
          'flags': 0,
          'tag': 'issue',
          'value': 'letsencrypt.org',
        },
      });
      final doh = DnsRecord.fromJson(<String, Object?>{
        'type': 'CAA',
        'name': 'example.com',
        'content': '0 issuewild "Sectigo.com"',
      });

      expect(api.caaFlags, 0);
      expect(api.content, '0 issue "letsencrypt.org"');
      expect(doh.caaTag, 'issuewild');
      expect(doh.caaValue, 'Sectigo.com');
      expect(doh.canonicalContent, '0 issuewild sectigo.com');
      expect(
        DnsRecord.fromJson(api.toCloudflareJson()).canonicalContent,
        api.canonicalContent,
      );
    });

    test('round trips NS records and tags', () {
      const record = DnsRecord(
        type: DnsRecordType.ns,
        name: 'dev.example.com',
        content: 'ns1.example.net',
        tags: <String>['env:dev', 'owner'],
      );

      final parsed = DnsRecord.fromJson(record.toCloudflareJson());

      expect(parsed.type, DnsRecordType.ns);
      expect(parsed.content, 'ns1.example.net');
      expect(parsed.tags, <String>['env:dev', 'owner']);
      expect(
        const DnsRecord(
          type: DnsRecordType.a,
          name: 'example.com',
          content: '192.0.2.1',
        ).toCloudflareJson()['tags'],
        isEmpty,
      );
    });
  });

  group('DnsRecordValidator', () {
    test('accepts web and Minecraft records', () {
      const web = DnsRecord(
        type: DnsRecordType.a,
        name: 'example.com',
        content: '192.0.2.10',
      );
      final minecraft = DnsRecord.srv(
        name: '_minecraft._tcp.example.com',
        priority: 0,
        weight: 0,
        port: 25566,
        target: 'mc.example.com',
      );

      expect(DnsRecordValidator.validate(web), isEmpty);
      expect(DnsRecordValidator.validate(minecraft), isEmpty);
    });

    test('rejects invalid IP, TTL, and SRV port', () {
      const invalidA = DnsRecord(
        type: DnsRecordType.a,
        name: 'example.com',
        content: '999.2.3.4',
        ttl: 30,
      );
      final invalidSrv = DnsRecord.srv(
        name: '_minecraft._tcp.example.com',
        priority: 0,
        weight: 0,
        port: 70000,
        target: 'mc.example.com',
      );

      expect(
        DnsRecordValidator.validate(invalidA).map((issue) => issue.code),
        containsAll(<String>['invalid_ipv4', 'invalid_ttl']),
      );
      expect(
        DnsRecordValidator.validate(invalidSrv).single.code,
        'invalid_port',
      );
    });

    test('accepts the zone apex and underscore verification names', () {
      const apex = DnsRecord(
        type: DnsRecordType.a,
        name: '@',
        content: '192.0.2.10',
      );
      const dmarc = DnsRecord(
        type: DnsRecordType.txt,
        name: '_dmarc.example.com',
        content: 'v=DMARC1; p=none',
      );
      const underscoreHost = DnsRecord(
        type: DnsRecordType.a,
        name: '_bad.example.com',
        content: '192.0.2.10',
      );

      expect(DnsRecordValidator.validate(apex), isEmpty);
      expect(DnsRecordValidator.validate(dmarc), isEmpty);
      expect(
        DnsRecordValidator.validate(underscoreHost).single.code,
        'invalid_name',
      );
    });

    test('validates MX, CAA, and NS fields', () {
      final validMx = DnsRecord.mx(
        name: 'example.com',
        priority: 10,
        mailServer: 'mail.example.com',
      );
      final invalidMx = DnsRecord.mx(
        name: 'example.com',
        priority: 70000,
        mailServer: 'not a host',
      );
      final validCaa = DnsRecord.caa(
        name: 'example.com',
        tag: 'iodef',
        value: 'mailto:security@example.com',
      );
      final invalidCaa = DnsRecord.caa(
        name: 'example.com',
        flags: 256,
        tag: 'contactemail',
        value: '"quoted"',
      );
      const invalidNs = DnsRecord(
        type: DnsRecordType.ns,
        name: 'dev.example.com',
        content: '',
        tags: <String>[' '],
      );

      expect(DnsRecordValidator.validate(validMx), isEmpty);
      expect(
        DnsRecordValidator.validate(invalidMx).map((issue) => issue.code),
        <String>['invalid_priority', 'invalid_target'],
      );
      expect(DnsRecordValidator.validate(validCaa), isEmpty);
      expect(
        DnsRecordValidator.validate(invalidCaa).map((issue) => issue.code),
        <String>['invalid_flags', 'invalid_caa_tag', 'invalid_caa_value'],
      );
      expect(
        DnsRecordValidator.validate(invalidNs).map((issue) => issue.code),
        <String>['invalid_tag', 'invalid_target'],
      );
    });

    test('enforces Cloudflare comment and tag limits', () {
      List<String> codes({String? comment, List<String> tags = const []}) =>
          DnsRecordValidator.validate(
            DnsRecord(
              type: DnsRecordType.a,
              name: 'example.com',
              content: '192.0.2.1',
              comment: comment,
              tags: tags,
            ),
          ).map((issue) => issue.code).toList();

      expect(codes(comment: 'x' * 500, tags: ['env:prod', 'owner']), isEmpty);
      expect(codes(comment: 'x' * 501), <String>['comment_too_long']);
      expect(codes(tags: ['bad name:x']), <String>['invalid_tag']);
      expect(codes(tags: ['env:${'v' * 101}']), <String>['invalid_tag']);
      expect(codes(tags: [for (var i = 0; i < 21; i++) 't$i']), <String>[
        'too_many_tags',
      ]);
      expect(
        const DnsRecord(
          type: DnsRecordType.a,
          name: 'example.com',
          content: '192.0.2.1',
          comment: '',
        ).toCloudflareJson()['comment'],
        '',
      );
    });
  });

  group('HTTPS, SVCB, and PTR', () {
    test('parse HTTPS from the Cloudflare API and from DoH', () {
      final api = DnsRecord.fromJson(<String, Object?>{
        'id': 'https-1',
        'type': 'HTTPS',
        'name': 'example.com',
        'content': '1 . alpn="h3,h2"',
        'data': <String, Object?>{
          'priority': 1,
          'target': '.',
          'value': 'alpn="h3,h2"',
        },
      });
      final doh = DnsRecord.fromJson(<String, Object?>{
        'type': 'HTTPS',
        'name': 'example.com',
        'content': '1 . alpn=h3,h2',
      });

      expect(api.priority, 1);
      expect(api.target, '.');
      expect(api.svcParams, 'alpn="h3,h2"');
      expect(doh.svcParams, 'alpn=h3,h2');
      // DoH drops the quotes, so both must still match.
      expect(doh.canonicalContent, api.canonicalContent);
      expect(api.toCloudflareJson()['data'], <String, Object?>{
        'priority': 1,
        'target': '.',
        'value': 'alpn="h3,h2"',
      });
    });

    test('round trip SVCB and PTR records', () {
      final svcb = DnsRecord.svcb(
        name: '_8443._foo.example.com',
        priority: 1,
        target: 'svc.example.com',
        params: 'port=8443',
      );
      final parsed = DnsRecord.fromJson(svcb.toCloudflareJson());
      expect(parsed.type, DnsRecordType.svcb);
      expect(parsed.content, '1 svc.example.com port=8443');
      expect(parsed.svcParams, 'port=8443');

      const ptr = DnsRecord(
        type: DnsRecordType.ptr,
        name: '1.2.0.192.in-addr.arpa',
        content: 'host.example.com',
      );
      expect(ptr.toCloudflareJson()['content'], 'host.example.com');
      expect(DnsRecordValidator.validate(ptr), isEmpty);
    });

    test('validate service binding priority, target, and alias mode', () {
      expect(
        DnsRecordValidator.validate(
          DnsRecord.https(name: 'example.com', priority: 1, params: 'alpn=h2'),
        ),
        isEmpty,
      );
      expect(
        DnsRecordValidator.validate(
          DnsRecord.https(
            name: 'example.com',
            priority: 0,
            target: 'cdn.example.net',
          ),
        ),
        isEmpty,
      );

      List<String> codes(DnsRecord record) => DnsRecordValidator.validate(
        record,
      ).map((issue) => issue.code).toList();
      expect(
        codes(
          DnsRecord.https(name: 'example.com', priority: 0, params: 'alpn=h2'),
        ),
        contains('alias_with_params'),
      );
      expect(
        codes(DnsRecord.svcb(name: 'example.com', priority: 70000, target: '')),
        containsAll(<String>['invalid_priority', 'invalid_target']),
      );
      expect(
        codes(
          const DnsRecord(
            type: DnsRecordType.ptr,
            name: '1.2.0.192.in-addr.arpa',
            content: 'not a host',
          ),
        ),
        contains('invalid_target'),
      );
    });
  });

  group('DnsZoneFile', () {
    const zoneFile = r'''
;; Exported from somewhere
example.com.	3600	IN	SOA	ns.example.net. admin.example.com. 1 7200 3600 1209600 300
$TTL 1h
@	IN	A	192.0.2.1 ; cf_tags=cf-proxied:true
www	300	IN	CNAME	@ ; cf_tags=cf-proxied:false
	IN	TXT	"say \"hi\"" " and bye"
_minecraft._tcp	60	IN	SRV	0 5 25565 mc
@	IN	MX	10 mail.example.net.
@	IN	CAA	0 issue "letsencrypt.org"
@	IN	HTTPS	1 . alpn="h3,h2"
_8443._svc	IN	SVCB	( 1
		svc.example.net. port=8443 )
host	IN	LOC	1 2 3
''';

    test('parses directives, owners, TTLs, and every supported type', () {
      final result = DnsZoneFile.parse(zoneFile, origin: 'example.com');
      final records = result.records;

      expect(records.map((r) => r.type.wireName), <String>[
        'A',
        'CNAME',
        'TXT',
        'SRV',
        'MX',
        'CAA',
        'HTTPS',
        'SVCB',
      ]);
      expect(records[0].name, 'example.com');
      expect(records[0].ttl, 3600);
      expect(records[0].proxied, isTrue);
      expect(records[1].content, 'example.com');
      expect(records[1].proxied, isFalse);
      // A blank owner repeats the previous one; quoted strings concatenate.
      expect(records[2].name, 'www.example.com');
      expect(records[2].content, 'say "hi" and bye');
      expect(records[3].target, 'mc.example.com');
      expect(records[4].content, 'mail.example.net');
      expect(records[5].caaValue, 'letsencrypt.org');
      expect(records[6].svcParams, 'alpn="h3,h2"');
      expect(records[7].name, '_8443._svc.example.com');
      expect(records[7].target, 'svc.example.net');
      expect(
        records.every((r) => DnsRecordValidator.validate(r).isEmpty),
        isTrue,
      );

      expect(
        result.issues.map((issue) => (issue.line, issue.code)),
        <(int, String)>[(2, 'unsupported_type'), (13, 'unsupported_type')],
      );
    });

    test('round trips through encode', () {
      final records = DnsZoneFile.parse(
        zoneFile,
        origin: 'example.com',
      ).records;
      final encoded = DnsZoneFile.encode(records, origin: 'example.com');
      final again = DnsZoneFile.parse(encoded, origin: 'example.com');

      expect(
        encoded,
        contains(
          'example.com.\t3600\tIN\tA\t192.0.2.1 ; cf_tags=cf-proxied:true',
        ),
      );
      expect(
        encoded,
        contains(
          '_minecraft._tcp.example.com.\t60\tIN\tSRV\t0 5 25565 mc.example.com.',
        ),
      );
      expect(again.issues, isEmpty);
      expect(
        again.records.map(
          (r) => '${r.name} ${r.type.wireName} ${r.canonicalContent} ${r.ttl}',
        ),
        records.map(
          (r) => '${r.name} ${r.type.wireName} ${r.canonicalContent} ${r.ttl}',
        ),
      );
    });

    test('encodes zone-relative names and splits long TXT values', () {
      final encoded = DnsZoneFile.encode(<DnsRecord>[
        const DnsRecord(type: DnsRecordType.a, name: '@', content: '192.0.2.1'),
        DnsRecord(type: DnsRecordType.txt, name: 'long', content: 'x' * 300),
      ], origin: 'example.com');

      expect(encoded, contains('example.com.\t1\tIN\tA\t192.0.2.1\n'));
      expect(
        encoded,
        contains('long.example.com.\t1\tIN\tTXT\t"${'x' * 255}" "${'x' * 45}"'),
      );
      final txt = DnsZoneFile.parse(
        encoded,
        origin: 'example.com',
      ).records.last;
      expect(txt.content, 'x' * 300);
    });

    test('reports malformed records', () {
      final result = DnsZoneFile.parse(
        'www IN MX mail\n IN A 192.0.2.1\nfoo 300\n',
        origin: 'example.com',
      );

      expect(result.records.single.name, 'www.example.com');
      expect(result.issues.map((issue) => issue.code), <String>[
        'invalid_rdata',
        'missing_type',
      ]);
    });
  });
}
