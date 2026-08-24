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
  });
}
