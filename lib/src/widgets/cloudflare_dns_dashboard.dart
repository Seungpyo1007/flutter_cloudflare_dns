import 'package:flutter/material.dart';

import '../diagnostics/dns_diagnostics.dart';
import '../gateway/cloudflare_dns_gateway.dart';
import '../models/dns_health.dart';
import '../models/dns_record.dart';
import '../models/dns_zone.dart';
import 'dns_record_editor_sheet.dart';
import 'dns_record_list.dart';
import 'dns_sync_status_icon.dart';
import 'domain_health_card.dart';

/// Ready-to-use Material 3 dashboard for Cloudflare DNS.
class CloudflareDnsDashboard extends StatefulWidget {
  /// Creates a dashboard.
  const CloudflareDnsDashboard({
    super.key,
    required this.gateway,
    this.diagnostics,
    this.initialZoneName,
    this.padding = const EdgeInsets.fromLTRB(20, 8, 20, 120),
  });

  /// DNS gateway used for records and mutations.
  final CloudflareDnsGateway gateway;

  /// Public DNS checker. A default instance is created when omitted.
  final DnsDiagnostics? diagnostics;

  /// Preferred zone selected after loading.
  final String? initialZoneName;

  /// Dashboard content padding.
  final EdgeInsetsGeometry padding;

  @override
  State<CloudflareDnsDashboard> createState() => _CloudflareDnsDashboardState();
}

class _CloudflareDnsDashboardState extends State<CloudflareDnsDashboard> {
  List<DnsZone> _zones = const <DnsZone>[];
  List<DnsRecord> _records = const <DnsRecord>[];
  DnsZone? _selectedZone;
  DnsHealthReport? _report;
  _RecordFilter _filter = _RecordFilter.all;
  bool _loading = true;
  bool _writing = false;
  bool _checking = false;
  String? _error;
  String? _healthError;

  DnsDiagnostics get _diagnostics => widget.diagnostics ?? DnsDiagnostics();

  @override
  void initState() {
    super.initState();
    _loadZones();
  }

  Future<void> _loadZones() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final zones = await widget.gateway.listZones();
      if (!mounted) return;
      final selected = zones.isEmpty
          ? null
          : zones
                    .where((zone) => zone.name == widget.initialZoneName)
                    .firstOrNull ??
                zones.first;
      setState(() {
        _zones = zones;
        _selectedZone = selected;
      });
      if (selected != null) await _loadRecords();
    } on Object catch (error) {
      if (mounted) setState(() => _error = _safeMessage(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadRecords() async {
    final zone = _selectedZone;
    if (zone == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final records = await widget.gateway.listRecords(zone.id);
      if (!mounted) return;
      setState(() => _records = records);
      await _checkHealth();
    } on Object catch (error) {
      if (mounted) setState(() => _error = _safeMessage(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _checkHealth() async {
    final zone = _selectedZone;
    if (zone == null) return;
    setState(() {
      _checking = true;
      _healthError = null;
    });
    try {
      final expected = _records.where((record) => record.proxied != true);
      final report = await _diagnostics.check(
        zone.name,
        types: const <DnsRecordType>[],
        expectedRecords: expected,
      );
      if (mounted) setState(() => _report = report);
    } on Object catch (error) {
      if (mounted) setState(() => _healthError = _safeMessage(error));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _pickZone() async {
    if (_zones.isEmpty || _writing) return;
    final selected = await showModalBottomSheet<DnsZone>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: Text(
                  'Choose a zone',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              for (final zone in _zones)
                ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  leading: CircleAvatar(
                    child: Text(zone.name.characters.first.toUpperCase()),
                  ),
                  title: Text(zone.name),
                  subtitle: Text(zone.status ?? 'unknown'),
                  trailing: zone == _selectedZone
                      ? const Icon(Icons.check_circle_rounded)
                      : null,
                  selected: zone == _selectedZone,
                  onTap: () => Navigator.pop(context, zone),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected == null || selected == _selectedZone || !mounted) return;
    setState(() {
      _selectedZone = selected;
      _filter = _RecordFilter.all;
      _report = null;
    });
    await _loadRecords();
  }

  Future<void> _edit([DnsRecord? initial]) async {
    final zone = _selectedZone;
    if (zone == null) return;
    final record = await DnsRecordEditorSheet.show(
      context,
      zoneName: zone.name,
      initialRecord: initial,
    );
    if (record == null || !mounted) return;
    setState(() => _writing = true);
    try {
      if (initial?.id == null) {
        await widget.gateway.createRecord(zone.id, record);
      } else {
        await widget.gateway.updateRecord(zone.id, initial!.id!, record);
      }
      await _loadRecords();
    } on Object catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  Future<void> _delete(DnsRecord record) async {
    final zone = _selectedZone;
    if (zone == null || record.id == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_outline_rounded),
        title: const Text('Delete DNS record?'),
        content: Text(
          '${record.type.wireName} ${record.name} will be removed.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _writing = true);
    try {
      await widget.gateway.deleteRecord(zone.id, record.id!);
      await _loadRecords();
    } on Object catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  void _showError(Object error) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(_safeMessage(error))));
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final proxied = _records.where((record) => record.proxied == true).length;
    final services = _records
        .where((record) => record.type == DnsRecordType.srv)
        .length;
    final visibleRecords = _records
        .where((record) => _filter.includes(record))
        .toList(growable: false);

    return Stack(
      children: <Widget>[
        ColoredBox(
          color: colors.surface,
          child: RefreshIndicator(
            edgeOffset: 96,
            onRefresh: _selectedZone == null ? _loadZones : _loadRecords,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: <Widget>[
                SliverAppBar.large(
                  pinned: true,
                  stretch: true,
                  backgroundColor: colors.surface,
                  surfaceTintColor: colors.surfaceTint,
                  scrolledUnderElevation: 1,
                  leadingWidth: 72,
                  leading: const Center(child: _CloudflareMark()),
                  title: const Text('DNS'),
                  actions: <Widget>[
                    IconButton.filledTonal(
                      tooltip: 'Refresh records',
                      onPressed: _loading ? null : _loadRecords,
                      icon: DnsSyncStatusIcon(
                        active: _loading,
                        icon: Icons.refresh_rounded,
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                ),
                SliverToBoxAdapter(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: Padding(
                        padding: widget.padding,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            _ZoneSelector(
                              zone: _selectedZone,
                              onTap: _pickZone,
                            ),
                            const SizedBox(height: 16),
                            if (_selectedZone != null)
                              DomainHealthCard(
                                domain: _selectedZone!.name,
                                report: _report,
                                loading: _checking,
                                error: _healthError,
                                onRefresh: _checkHealth,
                              ),
                            const SizedBox(height: 12),
                            _DnsSummary(
                              total: _records.length,
                              dnsOnly: _records.length - proxied,
                              services: services,
                            ),
                            if (_error != null) ...<Widget>[
                              const SizedBox(height: 16),
                              _DashboardError(
                                message: _error!,
                                onRetry: _loadZones,
                              ),
                            ],
                            const SizedBox(height: 32),
                            _SectionHeading(count: _records.length),
                            const SizedBox(height: 14),
                            _RecordFilterBar(
                              selected: _filter,
                              onSelected: (filter) {
                                setState(() => _filter = filter);
                              },
                            ),
                            const SizedBox(height: 14),
                            AnimatedSwitcher(
                              duration: const Duration(milliseconds: 300),
                              switchInCurve: Curves.easeOutCubic,
                              switchOutCurve: Curves.easeInCubic,
                              child: DnsRecordList(
                                key: ValueKey<_RecordFilter>(_filter),
                                records: visibleRecords,
                                enabled: !_writing,
                                onEdit: _edit,
                                onDelete: _delete,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          right: 20,
          bottom: 20,
          child: SafeArea(
            child: FloatingActionButton.extended(
              heroTag: 'cloudflare_dns_add_record',
              tooltip: 'Add DNS record',
              onPressed: _selectedZone == null || _writing ? null : _edit,
              icon: const Icon(Icons.add_rounded),
              label: const Text('New record'),
            ),
          ),
        ),
        if (_loading || _writing)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(),
          ),
      ],
    );
  }
}

class _CloudflareMark extends StatelessWidget {
  const _CloudflareMark();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: colors.primaryContainer,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(16),
          topRight: Radius.circular(16),
          bottomLeft: Radius.circular(16),
          bottomRight: Radius.circular(6),
        ),
      ),
      child: Icon(Icons.cloud_rounded, color: colors.onPrimaryContainer),
    );
  }
}

class _ZoneSelector extends StatelessWidget {
  const _ZoneSelector({required this.zone, required this.onTap});

  final DnsZone? zone;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 14, 16),
          child: Row(
            children: <Widget>[
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: colors.primary,
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.language_rounded, color: colors.onPrimary),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'CURRENT ZONE',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      zone?.name ?? 'No zone selected',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              if (zone != null) ...<Widget>[
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Color(0xFF22A06B),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Active',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              const SizedBox(width: 4),
              const Icon(Icons.keyboard_arrow_down_rounded),
            ],
          ),
        ),
      ),
    );
  }
}

class _DnsSummary extends StatelessWidget {
  const _DnsSummary({
    required this.total,
    required this.dnsOnly,
    required this.services,
  });

  final int total;
  final int dnsOnly;
  final int services;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 18),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: _SummaryValue(value: '$total', label: 'Records'),
          ),
          const SizedBox(height: 38, child: VerticalDivider()),
          Expanded(
            child: _SummaryValue(value: '$dnsOnly', label: 'DNS only'),
          ),
          const SizedBox(height: 38, child: VerticalDivider()),
          Expanded(
            child: _SummaryValue(value: '$services', label: 'Services'),
          ),
        ],
      ),
    );
  }
}

class _SummaryValue extends StatelessWidget {
  const _SummaryValue({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          value,
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: colors.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Records',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                'Tap a record to review or edit it',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Container(
          constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: colors.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Text(
            '$count',
            style: TextStyle(
              color: colors.onPrimaryContainer,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }
}

class _RecordFilterBar extends StatelessWidget {
  const _RecordFilterBar({required this.selected, required this.onSelected});

  final _RecordFilter selected;
  final ValueChanged<_RecordFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: <Widget>[
          for (final filter in _RecordFilter.values) ...<Widget>[
            FilterChip(
              selected: selected == filter,
              label: Text(filter.label),
              avatar: selected == filter ? Icon(filter.icon, size: 17) : null,
              onSelected: (_) => onSelected(filter),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

class _DashboardError extends StatelessWidget {
  const _DashboardError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.errorContainer,
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: <Widget>[
            Icon(Icons.error_outline_rounded, color: colors.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Could not load DNS records',
                    style: TextStyle(
                      color: colors.onErrorContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    message,
                    style: TextStyle(color: colors.onErrorContainer),
                  ),
                ],
              ),
            ),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

enum _RecordFilter {
  all('All', Icons.select_all_rounded),
  web('Web', Icons.public_rounded),
  verification('Verify', Icons.verified_outlined),
  service('Services', Icons.sports_esports_outlined),
  mail('Mail', Icons.mail_outline_rounded),
  infrastructure('Infra', Icons.dns_outlined);

  const _RecordFilter(this.label, this.icon);

  final String label;
  final IconData icon;

  bool includes(DnsRecord record) => switch (this) {
    _RecordFilter.all => true,
    _RecordFilter.web =>
      record.type == DnsRecordType.a ||
          record.type == DnsRecordType.aaaa ||
          record.type == DnsRecordType.cname,
    _RecordFilter.verification => record.type == DnsRecordType.txt,
    _RecordFilter.service => record.type == DnsRecordType.srv,
    _RecordFilter.mail => record.type == DnsRecordType.mx,
    _RecordFilter.infrastructure =>
      record.type == DnsRecordType.ns || record.type == DnsRecordType.caa,
  };
}

String _safeMessage(Object error) {
  if (error is CloudflareDnsException) return error.message;
  return 'An unexpected DNS error occurred.';
}
