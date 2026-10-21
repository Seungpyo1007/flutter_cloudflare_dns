// Dashboard flows added in 0.3.0, plus RTL, large text, and dark mode.
import 'package:flutter/material.dart';
import 'package:flutter_cloudflare_dns/flutter_cloudflare_dns.dart';
import 'package:flutter_test/flutter_test.dart';

const _records = <DnsRecord>[
  DnsRecord(
    id: 'a-1',
    type: DnsRecordType.a,
    name: 'example.com',
    content: '192.0.2.1',
    proxied: false,
  ),
  DnsRecord(
    id: 'a-2',
    type: DnsRecordType.a,
    name: 'www.example.com',
    content: '192.0.2.2',
    proxied: false,
  ),
  DnsRecord(
    id: 'idn-1',
    type: DnsRecordType.a,
    name: 'xn--3e0b707e.example.com',
    content: '192.0.2.3',
    proxied: false,
  ),
];

Widget _app(
  Widget child, {
  TextDirection direction = TextDirection.ltr,
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) => MaterialApp(
  theme: ThemeData(useMaterial3: true, brightness: brightness),
  home: Directionality(
    textDirection: direction,
    child: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(body: child),
      ),
    ),
  ),
);

void main() {
  testWidgets('dashboard lays out right to left', (tester) async {
    await tester.pumpWidget(
      _app(
        CloudflareDnsDashboard(
          gateway: _Gateway(),
          diagnostics: _Diagnostics(),
        ),
        direction: TextDirection.rtl,
      ),
    );
    await tester.pumpAndSettle();

    final fab = tester.getRect(find.byType(FloatingActionButton));
    final screen = tester.getRect(find.byType(Scaffold));
    // The add button sits at the start (left) edge in RTL.
    expect(fab.left, lessThan(screen.width / 2));
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('dashboard and sheets fit text scale 2 ($brightness)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          CloudflareDnsDashboard(
            gateway: _Gateway(),
            diagnostics: _Diagnostics(),
          ),
          textScale: 2,
          brightness: brightness,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('DNSSEC validated'), findsOneWidget);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.byType(DnsRecordEditorSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Cancel'));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Zone file'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import zone file'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('zone-file-input')),
        'www 300 IN CNAME example.net.\napi 300 IN A 198.51.100.1\n',
      );
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      expect(find.byType(DnsZoneImportSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('record list shows internationalized names in Unicode', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        CloudflareDnsDashboard(
          gateway: _Gateway(),
          diagnostics: _Diagnostics(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('한국.example.com'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('한국.example.com'), findsOneWidget);
    expect(find.text('xn--3e0b707e.example.com'), findsOneWidget);
  });

  testWidgets('editor blocks a CNAME next to other records', (tester) async {
    await tester.pumpWidget(
      _app(
        const DnsRecordEditorSheet(
          zoneName: 'example.com',
          existingRecords: _records,
        ),
      ),
    );
    final cnameType = find.bySemanticsLabel('CNAME record type');
    await tester.ensureVisible(cnameType);
    await tester.tap(cnameType);
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'www');
    await tester.enterText(fields.at(1), 'example.net');
    await tester.scrollUntilVisible(
      find.text('Save record'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Save record'));
    await tester.pumpAndSettle();
    expect(find.textContaining('cannot share its name'), findsOneWidget);
  });

  testWidgets('editor locks TTL to automatic for proxied records', (
    tester,
  ) async {
    DnsRecord? saved;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              saved = await DnsRecordEditorSheet.show(
                context,
                zoneName: 'example.com',
                initialRecord: const DnsRecord(
                  type: DnsRecordType.a,
                  name: 'api.example.com',
                  content: '192.0.2.9',
                  ttl: 3600,
                  proxied: false,
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byType(Switch),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(
      find.text('Proxied records always use automatic TTL.'),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.text('Save record'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('Save record'));
    await tester.pumpAndSettle();
    expect(saved?.proxied, isTrue);
    expect(saved?.ttl, 1);
  });

  testWidgets('import sends batches of importBatchSize and lists failures', (
    tester,
  ) async {
    _tallView(tester);
    final gateway = _Gateway(failBatch: 2);
    await tester.pumpWidget(
      _app(
        CloudflareDnsDashboard(
          gateway: gateway,
          diagnostics: _Diagnostics(),
          importBatchSize: 2,
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
      <String>[
        for (var i = 0; i < 5; i++) 'h$i 300 IN A 198.51.100.$i',
        // Conflicts with the A record at www, so the preview drops it.
        'www 300 IN CNAME example.net.',
      ].join('\n'),
    );
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(find.textContaining('cannot share its name'), findsOneWidget);
    await tester.ensureVisible(find.text('Import 5 records'));
    await tester.tap(find.text('Import 5 records'));
    await tester.pumpAndSettle();

    expect(gateway.batchSizes, <int>[2, 2]);
    expect(find.text('Imported 2 of 5 records'), findsOneWidget);
    expect(find.text('Batch rejected'), findsNWidgets(2));
    expect(
      find.text('Not sent after an earlier batch failed.'),
      findsOneWidget,
    );
  });

  testWidgets('dashboard tracks a deleted record until resolvers drop it', (
    tester,
  ) async {
    _tallView(tester);
    final diagnostics = _Diagnostics();
    await tester.pumpWidget(
      _app(
        CloudflareDnsDashboard(
          gateway: _Gateway(),
          diagnostics: diagnostics,
          propagationCheckInterval: const Duration(seconds: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Record actions').at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('removing from public DNS'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.textContaining('gone from public DNS'), findsOneWidget);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Deleted records'), findsNothing);
    expect(diagnostics.removalPolls, greaterThanOrEqualTo(2));
  });
}

/// A phone-sized view tall enough to show the whole dashboard.
void _tallView(WidgetTester tester) {
  tester.view.physicalSize = const Size(1290, 5000);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
}

class _Gateway implements BatchCapableGateway {
  _Gateway({this.failBatch});

  /// 1-based batch number that fails, if any.
  final int? failBatch;
  final records = List<DnsRecord>.of(_records);
  final batchSizes = <int>[];

  @override
  Future<List<DnsZone>> listZones() async => const <DnsZone>[
    DnsZone(id: 'zone-1', name: 'example.com'),
  ];

  @override
  Future<List<DnsRecord>> listRecords(String zoneId) async =>
      List<DnsRecord>.of(records);

  @override
  Future<DnsRecord> createRecord(String zoneId, DnsRecord record) async {
    final saved = record.copyWith(id: 'new-${records.length}');
    records.add(saved);
    return saved;
  }

  @override
  Future<DnsRecord> updateRecord(
    String zoneId,
    String recordId,
    DnsRecord record,
  ) async => record.copyWith(id: recordId);

  @override
  Future<void> deleteRecord(String zoneId, String recordId) async =>
      records.removeWhere((record) => record.id == recordId);

  @override
  Future<DnsBatchResult> batch(
    String zoneId, {
    Iterable<DnsRecord> posts = const <DnsRecord>[],
    Iterable<DnsRecord> patches = const <DnsRecord>[],
    Iterable<String> deletes = const <String>[],
  }) async {
    batchSizes.add(posts.length);
    if (batchSizes.length == failBatch) {
      throw const CloudflareDnsException('Batch rejected');
    }
    final added = <DnsRecord>[
      for (final record in posts) record.copyWith(id: 'b-${records.length}'),
    ];
    records.addAll(added);
    return DnsBatchResult(posts: added);
  }
}

/// Healthy, DNSSEC-validated answers; a deleted record disappears from the
/// second poll on.
class _Diagnostics extends DnsDiagnostics {
  var removalPolls = 0;

  @override
  Future<DnsHealthReport> check(
    String domain, {
    Iterable<DnsRecordType> types = const <DnsRecordType>[],
    Iterable<DnsRecord> expectedRecords = const <DnsRecord>[],
  }) async => DnsHealthReport(
    domain: domain,
    checkedAt: DateTime.utc(2026),
    answers: const <String, List<DnsRecord>>{},
    issues: const <DnsIssue>[],
    dnssecValidated: true,
  );

  @override
  Stream<DnsResolverComparison> watchPropagation(
    DnsRecord record, {
    Duration interval = const Duration(seconds: 15),
    Duration timeout = const Duration(minutes: 10),
    Map<String, Uri>? resolvers,
    bool removal = false,
  }) async* {
    while (true) {
      removalPolls++;
      final gone = removalPolls > 1;
      final comparison = DnsResolverComparison(
        name: record.name,
        type: record.type,
        answers: <String, List<DnsRecord>>{
          'Cloudflare': gone ? const <DnsRecord>[] : <DnsRecord>[record],
          'Google': gone ? const <DnsRecord>[] : <DnsRecord>[record],
        },
      );
      yield comparison;
      if (removal ? comparison.lacks(record) : comparison.matches(record)) {
        return;
      }
      await Future<void>.delayed(interval);
    }
  }
}
