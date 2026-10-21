// Record policy, zone-wide rules, IDN, and zone file attributes (0.3.0).
import 'package:flutter_cloudflare_dns/flutter_cloudflare_dns.dart';
import 'package:flutter_test/flutter_test.dart';

List<String> _codes(DnsRecord record, [DnsRecordPolicy? policy]) =>
    DnsRecordValidator.validate(
      record,
      policy: policy ?? const DnsRecordPolicy(),
    ).map((issue) => issue.code).toList();

DnsRecord _a(String name, {int ttl = 1, bool? proxied, String? id}) =>
    DnsRecord(
      id: id,
      type: DnsRecordType.a,
      name: name,
      content: '192.0.2.1',
      ttl: ttl,
      proxied: proxied,
    );

void main() {
  group('TTL policy', () {
    test('accepts automatic and 60 to 86400 seconds by default', () {
      expect(_codes(_a('example.com')), isEmpty);
      expect(_codes(_a('example.com', ttl: 60)), isEmpty);
      expect(_codes(_a('example.com', ttl: 86400)), isEmpty);
      expect(_codes(_a('example.com', ttl: 30)), contains('invalid_ttl'));
      expect(_codes(_a('example.com', ttl: 86401)), contains('invalid_ttl'));
    });

    test('allows 30 seconds on Enterprise', () {
      expect(
        _codes(_a('example.com', ttl: 30), DnsRecordPolicy.enterprise),
        isEmpty,
      );
      expect(
        _codes(_a('example.com', ttl: 29), DnsRecordPolicy.enterprise),
        contains('invalid_ttl'),
      );
    });

    test('requires automatic TTL on proxied records', () {
      expect(
        _codes(_a('example.com', ttl: 300, proxied: true)),
        contains('proxied_ttl'),
      );
      expect(_codes(_a('example.com', proxied: true)), isEmpty);
    });
  });

  group('content limits', () {
    test('rejects TXT content over the 4096-byte record limit', () {
      DnsRecord txt(int length) => DnsRecord(
        type: DnsRecordType.txt,
        name: 'example.com',
        content: 'a' * length,
      );
      // 4080 bytes in 16 strings of 255 plus 16 length bytes = 4096.
      expect(_codes(txt(4080)), isEmpty);
      expect(_codes(txt(4081)), contains('txt_too_long'));
    });
  });

  group('internationalized names', () {
    test('converts between Unicode and Punycode', () {
      expect(DnsName.toAscii('한국.example.com'), 'xn--3e0b707e.example.com');
      expect(DnsName.toAscii('Bücher.de'), 'xn--bcher-kva.de');
      expect(DnsName.toUnicode('xn--mnchen-ost-9db.de'), 'münchen-ost.de');
      expect(DnsName.toUnicode('xn--r8jz45g.xn--zckzah'), '例え.テスト');
      expect(DnsName.toAscii('plain.example.com'), 'plain.example.com');
      // Malformed labels are left alone.
      expect(DnsName.toUnicode('xn--zz!.example'), 'xn--zz!.example');
    });

    test('validates and sends Unicode names in Punycode', () {
      const record = DnsRecord(
        type: DnsRecordType.cname,
        name: 'www.한국.com',
        content: 'bücher.de',
      );
      expect(_codes(record), isEmpty);
      final json = record.toCloudflareJson();
      expect(json['name'], 'www.xn--3e0b707e.com');
      expect(json['content'], 'xn--bcher-kva.de');
    });

    test('mentions Punycode when a name is invalid', () {
      final issue = DnsRecordValidator.validate(_a('bad_name.example.com'));
      expect(issue.single.message, contains('xn--'));
    });
  });

  group('null MX and SRV', () {
    test('accepts a null MX with priority 0 only', () {
      expect(
        _codes(DnsRecord.mx(name: 'example.com', priority: 0, mailServer: '.')),
        isEmpty,
      );
      expect(
        _codes(
          DnsRecord.mx(name: 'example.com', priority: 10, mailServer: '.'),
        ),
        contains('invalid_null_mx'),
      );
    });

    test('accepts SRV target "." for no service, with port 0', () {
      expect(
        _codes(
          DnsRecord.srv(
            name: '_sip._tcp.example.com',
            priority: 0,
            weight: 0,
            port: 0,
            target: '.',
          ),
        ),
        isEmpty,
      );
      expect(
        _codes(
          DnsRecord.srv(
            name: '_sip._tcp.example.com',
            priority: 0,
            weight: 0,
            port: 0,
            target: 'sip.example.com',
          ),
        ),
        contains('invalid_port'),
      );
    });
  });

  group('svcParams', () {
    String? error(String params) => DnsRecordValidator.svcParamsError(params);

    test('accepts valid parameters', () {
      expect(error(''), isNull);
      expect(error('alpn="h3,h2" port=8443'), isNull);
      expect(
        error('alpn=h2 no-default-alpn ipv4hint=192.0.2.1,192.0.2.2'),
        isNull,
      );
      expect(error('ipv6hint="2001:db8::1" key65000=x'), isNull);
      expect(error('mandatory=alpn alpn=h3'), isNull);
      expect(error('alpn="h3, h2"'), isNull);
    });

    test('reports broken parameters', () {
      expect(error('=== "'), isNotNull);
      expect(error('alpn="h3'), contains('quote'));
      expect(error('colour=blue'), contains('Unknown'));
      expect(error('port=1 port=2'), contains('more than once'));
      expect(error('port=70000'), contains('port'));
      expect(error('ipv4hint=1.2.3'), contains('ipv4hint'));
      expect(error('no-default-alpn'), contains('alpn'));
      expect(error('no-default-alpn=1 alpn=h2'), contains('no value'));
      expect(error('mandatory=port alpn=h2'), contains('mandatory'));
      expect(error('alpn'), contains('needs a value'));
      expect(error('key70000=x'), contains('Unknown'));
    });

    test('blocks HTTPS records with invalid parameters', () {
      expect(
        _codes(
          DnsRecord.https(name: 'example.com', priority: 1, params: '=== "'),
        ),
        contains('invalid_svc_params'),
      );
    });
  });

  group('validateZone', () {
    List<String> zoneCodes(List<DnsRecord> records) =>
        DnsRecordValidator.validateZone(
          records,
          zoneName: 'example.com',
        ).map((issue) => issue.code).toList();

    test('rejects a CNAME sharing its name with other records', () {
      const cname = DnsRecord(
        type: DnsRecordType.cname,
        name: 'www',
        content: 'example.net',
      );
      expect(zoneCodes(<DnsRecord>[_a('www.example.com'), cname]), <String>[
        'cname_conflict',
      ]);
      expect(zoneCodes(<DnsRecord>[cname, _a('www.example.com')]), <String>[
        'cname_conflict',
      ]);
      expect(zoneCodes(<DnsRecord>[cname, _a('api.example.com')]), isEmpty);
    });

    test('rejects identical records', () {
      expect(zoneCodes(<DnsRecord>[_a('example.com'), _a('@')]), <String>[
        'duplicate_record',
      ]);
    });

    test('requires a null MX to be the only MX', () {
      expect(
        zoneCodes(<DnsRecord>[
          DnsRecord.mx(name: '@', priority: 0, mailServer: '.'),
          DnsRecord.mx(name: 'example.com', priority: 10, mailServer: 'mx.a'),
        ]),
        <String>['null_mx_conflict'],
      );
    });

    test('limits the combined content of one record set', () {
      DnsRecord txt(String value) =>
          DnsRecord(type: DnsRecordType.txt, name: '@', content: value);
      expect(zoneCodes(<DnsRecord>[txt('a' * 4000), txt('b' * 4000)]), isEmpty);
      expect(
        zoneCodes(<DnsRecord>[
          txt('a' * 4000),
          txt('b' * 4000),
          txt('c' * 300),
        ]),
        <String>['record_set_too_long'],
      );
    });

    test('notes an apex CNAME as flattened', () {
      final issues = DnsRecordValidator.validateZone(const <DnsRecord>[
        DnsRecord(type: DnsRecordType.cname, name: '@', content: 'a.net'),
      ], zoneName: 'example.com');
      expect(issues.single.code, 'cname_flattened');
      expect(issues.single.severity, DnsIssueSeverity.info);
    });

    test('validateInZone ignores the record being replaced', () {
      final existing = <DnsRecord>[_a('www.example.com', id: 'r1')];
      final edited = DnsRecord(
        id: 'r1',
        type: DnsRecordType.cname,
        name: 'www.example.com',
        content: 'example.net',
      );
      expect(
        DnsRecordValidator.validateInZone(
          edited,
          existing,
          zoneName: 'example.com',
        ),
        isEmpty,
      );
      expect(
        DnsRecordValidator.validateInZone(
          edited.copyWith(clear: {DnsRecordField.id}),
          existing,
          zoneName: 'example.com',
        ).map((issue) => issue.code),
        <String>['cname_conflict'],
      );
    });
  });

  group('copyWith', () {
    test('clears fields named in clear and keeps omitted and null ones', () {
      const record = DnsRecord(
        id: 'r1',
        type: DnsRecordType.a,
        name: 'example.com',
        content: '192.0.2.1',
        proxied: true,
        comment: 'note',
      );
      final cleared = record.copyWith(
        clear: {DnsRecordField.id, DnsRecordField.comment},
      );
      expect(cleared.id, isNull);
      expect(cleared.comment, isNull);
      expect(cleared.proxied, isTrue);
      expect(record.copyWith(ttl: 300).comment, 'note');
      expect(record.copyWith(comment: null).comment, 'note');
    });
  });

  group('toCloudflareJson', () {
    test('leaves out a missing MX priority', () {
      const record = DnsRecord(
        type: DnsRecordType.mx,
        name: 'example.com',
        content: 'mail.example.com',
      );
      expect(record.toCloudflareJson().containsKey('priority'), isFalse);
    });
  });

  group('zone file comments and tags', () {
    test('reads Cloudflare comments and tags', () {
      final records = DnsZoneFile.parse(
        'www 300 IN A 192.0.2.1 ; my note cf_tags=team:web,cf-proxied:false,urgent\n'
        'api 300 IN A 192.0.2.2 ; cf_tags=awesome\n'
        'mail 300 IN A 192.0.2.3 ; just a comment\n'
        'x 300 IN A 192.0.2.4 ; about cf_tags=old cf_tags=\n',
        origin: 'example.com',
      ).records;
      expect(records[0].comment, 'my note');
      expect(records[0].tags, <String>['team:web', 'urgent']);
      expect(records[0].proxied, isFalse);
      expect(records[1].comment, isNull);
      expect(records[1].tags, <String>['awesome']);
      expect(records[2].comment, 'just a comment');
      expect(records[2].tags, isEmpty);
      // A comment containing cf_tags= ends with an extra empty cf_tags=.
      expect(records[3].comment, 'about cf_tags=old');
      expect(records[3].tags, isEmpty);
    });

    test('round trips comments and tags', () {
      const records = <DnsRecord>[
        DnsRecord(
          type: DnsRecordType.a,
          name: 'www.example.com',
          content: '192.0.2.1',
          proxied: true,
          comment: 'web server',
          tags: <String>['team:web'],
        ),
        DnsRecord(
          type: DnsRecordType.txt,
          name: 'example.com',
          content: 'v=spf1 -all',
          comment: 'mentions cf_tags= here',
        ),
        DnsRecord(
          type: DnsRecordType.txt,
          name: 'a.example.com',
          content: 'x',
          tags: <String>['owner:dns'],
        ),
      ];
      final text = DnsZoneFile.encode(records, origin: 'example.com');
      expect(
        text,
        contains('192.0.2.1 ; web server cf_tags=team:web,cf-proxied:true'),
      );
      final parsed = DnsZoneFile.parse(text, origin: 'example.com').records;
      expect(parsed[0].comment, 'web server');
      expect(parsed[0].tags, <String>['team:web']);
      expect(parsed[0].proxied, isTrue);
      expect(parsed[1].comment, 'mentions cf_tags= here');
      expect(parsed[1].tags, isEmpty);
      expect(parsed[2].comment, isNull);
      expect(parsed[2].tags, <String>['owner:dns']);
    });

    test('writes internationalized names in Punycode', () {
      final text = DnsZoneFile.encode(const <DnsRecord>[
        DnsRecord(type: DnsRecordType.cname, name: 'www', content: '한국.com'),
      ], origin: 'bücher.de');
      expect(text, contains('www.xn--bcher-kva.de.'));
      expect(text, contains('xn--3e0b707e.com.'));
    });
  });
}
