import 'package:flutter/material.dart';
import 'package:flutter_cloudflare_dns/flutter_cloudflare_dns.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Cloudflare DNS',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const ExampleDashboard(),
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final colors = ColorScheme.fromSeed(
      seedColor: const Color(0xFFF6821F),
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: colors,
      scaffoldBackgroundColor: colors.surface,
      useMaterial3: true,
      appBarTheme: AppBarTheme(
        backgroundColor: colors.surface,
        foregroundColor: colors.onSurface,
        surfaceTintColor: colors.surfaceTint,
        centerTitle: false,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surfaceContainerLow,
        modalBackgroundColor: colors.surfaceContainerLow,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide(color: colors.primary, width: 2),
        ),
      ),
    );
  }
}

class ExampleDashboard extends StatefulWidget {
  const ExampleDashboard({super.key});

  @override
  State<ExampleDashboard> createState() => _ExampleDashboardState();
}

class _ExampleDashboardState extends State<ExampleDashboard> {
  final gateway = DemoDnsGateway();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CloudflareDnsDashboard(
        gateway: gateway,
        diagnostics: DemoDiagnostics(),
        initialZoneName: 'seungpyo.online',
      ),
    );
  }
}

/// Stable public-health result for a deterministic, offline-friendly demo.
class DemoDiagnostics extends DnsDiagnostics {
  @override
  Future<DnsHealthReport> check(
    String domain, {
    Iterable<DnsRecordType> types = const <DnsRecordType>[],
    Iterable<DnsRecord> expectedRecords = const <DnsRecord>[],
  }) async {
    // Long enough for the example to demonstrate the synchronized refresh
    // motion without making the dashboard feel artificially slow.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    return DnsHealthReport(
      domain: domain,
      checkedAt: DateTime.now().toUtc(),
      answers: const <String, List<DnsRecord>>{},
      issues: const <DnsIssue>[],
    );
  }
}

/// In-memory gateway so the example is safe to run without a Cloudflare token.
class DemoDnsGateway implements CloudflareDnsGateway {
  final records = <DnsRecord>[
    const DnsRecord(
      id: 'web',
      type: DnsRecordType.a,
      name: 'seungpyo.online',
      content: '76.76.21.21',
      proxied: false,
    ),
    const DnsRecord(
      id: 'verify',
      type: DnsRecordType.txt,
      name: 'seungpyo.online',
      content: 'google-site-verification=example',
      proxied: false,
    ),
    DnsRecord.srv(
      id: 'minecraft',
      name: '_minecraft._tcp.seungpyo.online',
      priority: 0,
      weight: 0,
      port: 25565,
      target: 'mc.seungpyo.online',
    ),
    DnsRecord.mx(
      id: 'mail',
      name: 'seungpyo.online',
      priority: 10,
      mailServer: 'mail.seungpyo.online',
    ),
    DnsRecord.caa(
      id: 'caa',
      name: 'seungpyo.online',
      tag: 'issue',
      value: 'letsencrypt.org',
    ),
  ];

  @override
  Future<List<DnsZone>> listZones() async => const <DnsZone>[
    DnsZone(id: 'demo-zone', name: 'seungpyo.online', status: 'active'),
  ];

  @override
  Future<List<DnsRecord>> listRecords(String zoneId) async => List.of(records);

  @override
  Future<DnsRecord> createRecord(String zoneId, DnsRecord record) async {
    final created = record.copyWith(id: 'demo-${records.length + 1}');
    records.add(created);
    return created;
  }

  @override
  Future<DnsRecord> updateRecord(
    String zoneId,
    String recordId,
    DnsRecord record,
  ) async {
    final index = records.indexWhere((item) => item.id == recordId);
    final updated = record.copyWith(id: recordId);
    records[index] = updated;
    return updated;
  }

  @override
  Future<void> deleteRecord(String zoneId, String recordId) async {
    records.removeWhere((record) => record.id == recordId);
  }
}
