import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cloudflare_dns/flutter_cloudflare_dns.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('dashboard renders loading, zone, records, and healthy state', (
    tester,
  ) async {
    final zoneCompleter = Completer<List<DnsZone>>();
    final gateway = TestGateway(zoneFuture: zoneCompleter.future);

    await tester.pumpWidget(
      _app(
        CloudflareDnsDashboard(
          gateway: gateway,
          diagnostics: HealthyDiagnostics(),
        ),
      ),
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    zoneCompleter.complete(const <DnsZone>[
      DnsZone(id: 'zone-1', name: 'example.com'),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('example.com'), findsWidgets);
    final recordList = tester.widget<DnsRecordList>(find.byType(DnsRecordList));
    expect(recordList.records.single.content, '192.0.2.1');
    expect(find.text('Public DNS is healthy'), findsOneWidget);
  });

  testWidgets('dashboard renders a sanitized authorization failure', (
    tester,
  ) async {
    final gateway = TestGateway(
      zoneError: const CloudflareDnsException('Unauthorized.', statusCode: 403),
    );

    await tester.pumpWidget(_app(CloudflareDnsDashboard(gateway: gateway)));
    await tester.pumpAndSettle();

    expect(find.text('Could not load DNS records'), findsOneWidget);
    expect(find.text('Unauthorized.'), findsOneWidget);
  });

  testWidgets('dashboard hides unexpected network error details', (
    tester,
  ) async {
    final gateway = TestGateway(zoneError: StateError('socket details'));

    await tester.pumpWidget(_app(CloudflareDnsDashboard(gateway: gateway)));
    await tester.pumpAndSettle();

    expect(find.text('An unexpected DNS error occurred.'), findsOneWidget);
    expect(find.textContaining('socket details'), findsNothing);
  });

  testWidgets('health card renders mismatch warning', (tester) async {
    final report = DnsHealthReport(
      domain: 'example.com',
      checkedAt: DateTime.utc(2026),
      answers: const <String, List<DnsRecord>>{},
      issues: const <DnsIssue>[
        DnsIssue(code: 'content_mismatch', message: 'Public answer differs.'),
      ],
    );

    await tester.pumpWidget(
      _app(DomainHealthCard(domain: 'example.com', report: report)),
    );

    expect(find.text('DNS check found warnings'), findsOneWidget);
    expect(find.text('• Public answer differs.'), findsOneWidget);
  });

  testWidgets('health sync rotates, settles, and confirms completion', (
    tester,
  ) async {
    final loading = ValueNotifier<bool>(false);
    final healthyReport = DnsHealthReport(
      domain: 'example.com',
      checkedAt: DateTime.utc(2026),
      answers: const <String, List<DnsRecord>>{},
      issues: const <DnsIssue>[],
    );
    addTearDown(loading.dispose);

    await tester.pumpWidget(
      _app(
        ValueListenableBuilder<bool>(
          valueListenable: loading,
          builder: (context, active, _) => DomainHealthCard(
            domain: 'example.com',
            report: healthyReport,
            loading: active,
            onRefresh: () {},
          ),
        ),
      ),
    );
    expect(find.bySemanticsLabel('Ready to sync'), findsOneWidget);

    loading.value = true;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 280));
    expect(find.bySemanticsLabel('Syncing'), findsNWidgets(2));
    expect(
      find.text('Public resolvers match your DNS configuration'),
      findsNothing,
    );

    loading.value = false;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.bySemanticsLabel('Sync complete'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 900));
    expect(find.bySemanticsLabel('Ready to sync'), findsOneWidget);
  });

  testWidgets('dashboard keeps mobile Material layout without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = TestGateway(
      zoneFuture: Future<List<DnsZone>>.value(const <DnsZone>[
        DnsZone(id: 'zone-1', name: 'example.com', status: 'active'),
      ]),
    );
    await tester.pumpWidget(
      _app(
        CloudflareDnsDashboard(
          gateway: gateway,
          diagnostics: HealthyDiagnostics(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SliverAppBar), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.byType(FilterChip), findsNWidgets(6));
    expect(tester.takeException(), isNull);
  });

  testWidgets('record editor uses a phone-friendly Material bottom sheet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () =>
                  DnsRecordEditorSheet.show(context, zoneName: 'example.com'),
              child: const Text('Open editor'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();

    expect(find.text('New DNS record'), findsOneWidget);
    expect(find.text('Record type'), findsOneWidget);
    expect(find.bySemanticsLabel('A record type'), findsOneWidget);
    expect(find.bySemanticsLabel('SRV record type'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<DnsRecordType>), findsNothing);
    expect(find.text('TTL (1 = Auto)'), findsNothing);
    expect(find.text('Time to live'), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
    expect(find.text('Live preview'), findsOneWidget);
    expect(find.text('Save record'), findsOneWidget);
    expect(tester.takeException(), isNull);

    final aType = find.bySemanticsLabel('A record type');
    final srvType = find.bySemanticsLabel('SRV record type');
    final aWidthBefore = tester.getSize(aType).width;
    final srvWidthBefore = tester.getSize(srvType).width;
    expect(aWidthBefore, greaterThan(srvWidthBefore));

    await tester.tap(srvType);
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('editor-type-mark-A')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('editor-type-mark-SRV')),
      findsOneWidget,
    );
    await tester.pump(const Duration(milliseconds: 260));
    expect(tester.getSize(aType).width, lessThan(aWidthBefore));
    expect(tester.getSize(srvType).width, greaterThan(srvWidthBefore));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('editor-type-mark-A')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('editor-type-mark-SRV')),
      findsOneWidget,
    );
    expect(
      tester.getSize(srvType).width,
      greaterThan(tester.getSize(aType).width),
    );
    expect(find.text('Priority'), findsOneWidget);
    expect(find.text('Weight'), findsOneWidget);
    expect(find.text('Port'), findsOneWidget);
    expect(find.text('Target hostname'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.bySemanticsLabel('Custom TTL'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('custom-ttl-field')),
      findsOneWidget,
    );
    expect(find.text('seconds'), findsOneWidget);
  });

  testWidgets('record editor shows MX and CAA fields on a phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    DnsRecord? saved;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () async {
                saved = await DnsRecordEditorSheet.show(
                  context,
                  zoneName: 'example.com',
                );
              },
              child: const Text('Open editor'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final mxType = find.bySemanticsLabel('MX record type');
    await tester.ensureVisible(mxType);
    await tester.tap(mxType);
    await tester.pumpAndSettle();
    expect(find.text('Mail server'), findsOneWidget);
    expect(find.text('Priority'), findsOneWidget);

    final caaType = find.bySemanticsLabel('CAA record type');
    await tester.ensureVisible(caaType);
    await tester.tap(caaType);
    await tester.pumpAndSettle();
    expect(find.text('Flags'), findsOneWidget);
    expect(find.text('Property'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.bySemanticsLabel('issuewild CAA property'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'example.com');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'letsencrypt.org'),
      'sectigo.com',
    );
    await tester.pump();
    expect(find.text('0 issuewild "sectigo.com"'), findsOneWidget);

    await tester.ensureVisible(find.text('Save record'));
    await tester.tap(find.text('Save record'));
    await tester.pumpAndSettle();
    expect(saved?.type, DnsRecordType.caa);
    expect(saved?.caaTag, 'issuewild');
    expect(saved?.caaValue, 'sectigo.com');
  });

  testWidgets('record list shows CAA values, MX priority, and tags', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        DnsRecordList(
          records: <DnsRecord>[
            DnsRecord.mx(
              name: 'example.com',
              priority: 10,
              mailServer: 'mail.example.com',
              tags: const <String>['team:mail'],
            ),
            DnsRecord.caa(
              name: 'example.com',
              tag: 'issue',
              value: 'letsencrypt.org',
            ),
          ],
        ),
      ),
    );

    expect(find.text('mail.example.com'), findsOneWidget);
    expect(find.text('Priority 10'), findsOneWidget);
    expect(find.text('team:mail'), findsOneWidget);
    expect(find.text('issue letsencrypt.org'), findsOneWidget);
  });

  testWidgets('record editor edits comment and tags', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    DnsRecord? saved;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () async {
                saved = await DnsRecordEditorSheet.show(
                  context,
                  zoneName: 'example.com',
                  initialRecord: const DnsRecord(
                    id: 'a-1',
                    type: DnsRecordType.a,
                    name: 'example.com',
                    content: '192.0.2.1',
                    comment: 'old note',
                    tags: <String>['env:dev'],
                  ),
                );
              },
              child: const Text('Open editor'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'old note'), '');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'env:dev'),
      'env:prod, owner:web',
    );
    await tester.ensureVisible(find.text('Save record'));
    await tester.tap(find.text('Save record'));
    await tester.pumpAndSettle();

    expect(saved?.comment, '');
    expect(saved?.tags, <String>['env:prod', 'owner:web']);
  });

  testWidgets('dashboard search filters records by name or value', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = TestGateway(
      zoneFuture: Future<List<DnsZone>>.value(const <DnsZone>[
        DnsZone(id: 'zone-1', name: 'example.com'),
      ]),
      records: const <DnsRecord>[
        DnsRecord(
          id: 'a-1',
          type: DnsRecordType.a,
          name: 'example.com',
          content: '192.0.2.1',
        ),
        DnsRecord(
          id: 'txt-1',
          type: DnsRecordType.txt,
          name: '_dmarc.example.com',
          content: 'v=DMARC1; p=none',
        ),
      ],
    );
    await tester.pumpWidget(
      _app(
        CloudflareDnsDashboard(
          gateway: gateway,
          diagnostics: HealthyDiagnostics(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    List<DnsRecord> visible() =>
        tester.widget<DnsRecordList>(find.byType(DnsRecordList)).records;
    final searchField = find.descendant(
      of: find.byType(SearchBar),
      matching: find.byType(TextField),
    );
    expect(visible(), hasLength(2));

    await tester.enterText(searchField, 'DMARC');
    await tester.pumpAndSettle();
    expect(visible().single.id, 'txt-1');

    await tester.enterText(searchField, '192.0.2');
    await tester.pumpAndSettle();
    expect(visible().single.id, 'a-1');
  });

  testWidgets('record menu offers copy and duplicate', (tester) async {
    DnsRecord? duplicated;
    await tester.pumpWidget(
      _app(
        DnsRecordList(
          records: const <DnsRecord>[
            DnsRecord(
              id: 'a-1',
              type: DnsRecordType.a,
              name: 'example.com',
              content: '192.0.2.1',
            ),
          ],
          onDuplicate: (record) => duplicated = record,
        ),
      ),
    );

    await tester.tap(find.byTooltip('Record actions'));
    await tester.pumpAndSettle();
    expect(find.text('Copy value'), findsOneWidget);
    await tester.tap(find.text('Duplicate'));
    await tester.pumpAndSettle();

    expect(duplicated?.id, 'a-1');
  });

  testWidgets('dashboard compares resolvers in a sheet', (tester) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = TestGateway(
      zoneFuture: Future<List<DnsZone>>.value(const <DnsZone>[
        DnsZone(id: 'zone-1', name: 'example.com'),
      ]),
    );
    await tester.pumpWidget(
      _app(
        CloudflareDnsDashboard(
          gateway: gateway,
          diagnostics: HealthyDiagnostics(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Compare resolvers'));
    await tester.pumpAndSettle();

    expect(find.text('Resolver comparison'), findsOneWidget);
    expect(
      find.text('1 of 1 records differ between resolvers.'),
      findsOneWidget,
    );
    expect(find.textContaining('Google: no answer'), findsOneWidget);
  });

  testWidgets('record editor shows HTTPS fields and saves a record', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    DnsRecord? saved;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () async {
                saved = await DnsRecordEditorSheet.show(
                  context,
                  zoneName: 'example.com',
                );
              },
              child: const Text('Open editor'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open editor'));
    await tester.pumpAndSettle();

    final httpsType = find.bySemanticsLabel('HTTPS record type');
    await tester.ensureVisible(httpsType);
    await tester.tap(httpsType);
    await tester.pumpAndSettle();
    expect(find.text('Parameters'), findsOneWidget);
    expect(find.bySemanticsLabel('PTR record type'), findsOneWidget);
    expect(find.bySemanticsLabel('SVCB record type'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.enterText(find.byType(TextFormField).first, 'example.com');
    await tester.enterText(find.widgetWithText(TextFormField, '0'), '1');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'alpn="h3,h2" port=8443'),
      'alpn="h3,h2"',
    );
    await tester.ensureVisible(find.text('Save record'));
    await tester.tap(find.text('Save record'));
    await tester.pumpAndSettle();

    expect(saved?.type, DnsRecordType.https);
    expect(saved?.priority, 1);
    expect(saved?.target, '.');
    expect(saved?.svcParams, 'alpn="h3,h2"');
  });

  testWidgets('record list shows propagation state', (tester) async {
    await tester.pumpWidget(
      _app(
        DnsRecordList(
          records: <DnsRecord>[
            const DnsRecord(
              id: 'a-1',
              type: DnsRecordType.a,
              name: 'example.com',
              content: '192.0.2.1',
            ),
            DnsRecord.https(
              name: 'example.com',
              priority: 0,
              target: 'cdn.net',
            ),
          ],
          propagation: const <String, DnsPropagationStatus>{
            'a-1': DnsPropagationStatus.timedOut,
            'example.com|HTTPS': DnsPropagationStatus.propagated,
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Not visible everywhere yet'), findsOneWidget);
    expect(find.text('Propagated'), findsOneWidget);
    expect(find.text('Alias'), findsOneWidget);
  });

  testWidgets('import sheet previews and returns only new valid records', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    List<DnsRecord>? imported;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () async {
                imported = await DnsZoneImportSheet.show(
                  context,
                  zoneName: 'example.com',
                  existingRecords: const <DnsRecord>[
                    DnsRecord(
                      id: 'a-1',
                      type: DnsRecordType.a,
                      name: 'example.com',
                      content: '192.0.2.1',
                    ),
                  ],
                );
              },
              child: const Text('Open import'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open import'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('zone-file-input')),
      '@ IN A 192.0.2.1\n'
      'www IN A 192.0.2.300\n'
      'api 300 IN AAAA 2001:db8::1\n'
      '@ IN SOA ns. admin. 1 2 3 4 5\n',
    );
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();

    expect(
      find.text('1 ready · 1 already exist · 1 invalid · 1 lines skipped'),
      findsOneWidget,
    );
    expect(find.text('Enter a valid IPv4 address.'), findsOneWidget);
    expect(find.text('Already exists, skipped'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Import 1 record'));
    await tester.pumpAndSettle();
    expect(imported?.single.name, 'api.example.com');
    expect(imported?.single.ttl, 300);
  });

  testWidgets('dashboard imports a zone file in one batch', (tester) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = BatchTestGateway();
    await tester.pumpWidget(
      _app(
        CloudflareDnsDashboard(
          gateway: gateway,
          diagnostics: HealthyDiagnostics(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Zone file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import zone file'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey<String>('zone-file-input')),
      'www 300 IN CNAME @\n_dmarc IN TXT "v=DMARC1; p=none"\n',
    );
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import 2 records'));
    await tester.pumpAndSettle();

    expect(gateway.batches, 1);
    expect(gateway.created, 0);
    expect(find.text('Imported 2 records'), findsOneWidget);
    final listed = tester.widget<DnsRecordList>(find.byType(DnsRecordList));
    expect(listed.records, hasLength(3));
  });

  testWidgets('dashboard copies the zone file', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final gateway = TestGateway(
      zoneFuture: Future<List<DnsZone>>.value(const <DnsZone>[
        DnsZone(id: 'zone-1', name: 'example.com'),
      ]),
    );
    await tester.pumpWidget(
      _app(
        CloudflareDnsDashboard(
          gateway: gateway,
          diagnostics: HealthyDiagnostics(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Zone file'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export zone file'));
    await tester.pumpAndSettle();

    expect(copied, contains('example.com.\t1\tIN\tA\t192.0.2.1'));
    expect(find.text('Zone file with 1 records copied'), findsOneWidget);
  });

  testWidgets('dashboard tracks propagation after a save', (tester) async {
    tester.view.physicalSize = const Size(390, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final gateway = BatchTestGateway();
    final diagnostics = PropagatingDiagnostics();
    await tester.pumpWidget(
      _app(
        CloudflareDnsDashboard(
          gateway: gateway,
          diagnostics: diagnostics,
          propagationCheckInterval: const Duration(seconds: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('192.0.2.1'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, '192.0.2.1'),
      '192.0.2.2',
    );
    await tester.ensureVisible(find.text('Save record'));
    await tester.tap(find.text('Save record'));
    // Stay under the 1 s poll interval: the first poll does not match yet.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Propagating'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Propagated'), findsOneWidget);
    expect(diagnostics.polls, 2);
  });
}

Widget _app(Widget child) => MaterialApp(
  theme: ThemeData(useMaterial3: true),
  home: Scaffold(body: child),
);

class HealthyDiagnostics extends DnsDiagnostics {
  @override
  Future<DnsHealthReport> check(
    String domain, {
    Iterable<DnsRecordType> types = const <DnsRecordType>[],
    Iterable<DnsRecord> expectedRecords = const <DnsRecord>[],
  }) async {
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
  }) async => <DnsResolverComparison>[
    for (final record in records)
      DnsResolverComparison(
        name: record.name,
        type: record.type,
        answers: <String, List<DnsRecord>>{
          'Cloudflare': <DnsRecord>[record],
          'Google': const <DnsRecord>[],
        },
      ),
  ];
}

class TestGateway implements CloudflareDnsGateway {
  TestGateway({
    this.zoneFuture,
    this.zoneError,
    this.records = _defaultRecords,
  });

  static const _defaultRecords = <DnsRecord>[
    DnsRecord(
      id: 'a-1',
      type: DnsRecordType.a,
      name: 'example.com',
      content: '192.0.2.1',
      proxied: false,
    ),
  ];

  final Future<List<DnsZone>>? zoneFuture;
  final Object? zoneError;
  final List<DnsRecord> records;

  @override
  Future<List<DnsZone>> listZones() async {
    await Future<void>.delayed(Duration.zero);
    if (zoneError case final error?) throw error;
    return zoneFuture ?? const <DnsZone>[];
  }

  @override
  Future<List<DnsRecord>> listRecords(String zoneId) async => records;

  @override
  Future<DnsRecord> createRecord(String zoneId, DnsRecord record) async =>
      record;

  @override
  Future<DnsRecord> updateRecord(
    String zoneId,
    String recordId,
    DnsRecord record,
  ) async => record;

  @override
  Future<void> deleteRecord(String zoneId, String recordId) async {}
}

/// Resolvers see the saved record from the second poll on.
class PropagatingDiagnostics extends HealthyDiagnostics {
  var polls = 0;

  @override
  Future<List<DnsResolverComparison>> compareResolvers(
    Iterable<DnsRecord> records, {
    Map<String, Uri>? resolvers,
  }) async {
    polls++;
    final record = records.single;
    return <DnsResolverComparison>[
      DnsResolverComparison(
        name: record.name,
        type: record.type,
        answers: <String, List<DnsRecord>>{
          'Cloudflare': <DnsRecord>[record],
          'Google': polls > 1 ? <DnsRecord>[record] : const <DnsRecord>[],
        },
      ),
    ];
  }
}

/// In-memory gateway that supports batches and counts writes.
class BatchTestGateway implements BatchCapableGateway {
  final records = <DnsRecord>[
    const DnsRecord(
      id: 'a-1',
      type: DnsRecordType.a,
      name: 'example.com',
      content: '192.0.2.1',
      proxied: false,
    ),
  ];
  var batches = 0;
  var created = 0;

  @override
  Future<List<DnsZone>> listZones() async => const <DnsZone>[
    DnsZone(id: 'zone-1', name: 'example.com'),
  ];

  @override
  Future<List<DnsRecord>> listRecords(String zoneId) async => List.of(records);

  @override
  Future<DnsRecord> createRecord(String zoneId, DnsRecord record) async {
    created++;
    final saved = record.copyWith(id: 'new-${records.length}');
    records.add(saved);
    return saved;
  }

  @override
  Future<DnsRecord> updateRecord(
    String zoneId,
    String recordId,
    DnsRecord record,
  ) async {
    final saved = record.copyWith(id: recordId);
    records[records.indexWhere((r) => r.id == recordId)] = saved;
    return saved;
  }

  @override
  Future<void> deleteRecord(String zoneId, String recordId) async {
    records.removeWhere((r) => r.id == recordId);
  }

  @override
  Future<DnsBatchResult> batch(
    String zoneId, {
    Iterable<DnsRecord> posts = const <DnsRecord>[],
    Iterable<DnsRecord> patches = const <DnsRecord>[],
    Iterable<String> deletes = const <String>[],
  }) async {
    batches++;
    final added = <DnsRecord>[
      for (final record in posts) record.copyWith(id: 'b-${records.length}'),
    ];
    records.addAll(added);
    return DnsBatchResult(posts: added);
  }
}
