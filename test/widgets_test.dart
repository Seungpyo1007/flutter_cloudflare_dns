import 'dart:async';

import 'package:flutter/material.dart';
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
}

class TestGateway implements CloudflareDnsGateway {
  TestGateway({this.zoneFuture, this.zoneError});

  final Future<List<DnsZone>>? zoneFuture;
  final Object? zoneError;

  @override
  Future<List<DnsZone>> listZones() async {
    await Future<void>.delayed(Duration.zero);
    if (zoneError case final error?) throw error;
    return zoneFuture ?? const <DnsZone>[];
  }

  @override
  Future<List<DnsRecord>> listRecords(String zoneId) async => const <DnsRecord>[
    DnsRecord(
      id: 'a-1',
      type: DnsRecordType.a,
      name: 'example.com',
      content: '192.0.2.1',
      proxied: false,
    ),
  ];

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
