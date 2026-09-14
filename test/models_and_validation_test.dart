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
        ).toCloudflareJson().containsKey('tags'),
        isFalse,
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
  });
}
