import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../diagnostics/dns_diagnostics.dart';
import '../gateway/cloudflare_dns_gateway.dart';
import '../models/dns_health.dart';
import '../models/dns_record.dart';
import '../models/dns_zone.dart';
import '../models/dns_zone_file.dart';
import '../validation/dns_record_validator.dart';
import 'dns_record_editor_sheet.dart';
import 'dns_record_list.dart';
import 'dns_sync_status_icon.dart';
import 'dns_zone_import_sheet.dart';
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
    this.propagationCheckInterval = const Duration(seconds: 15),
    this.propagationTimeout = const Duration(minutes: 10),
    this.maxHealthCheckRecords = 100,
    this.recordPolicy = const DnsRecordPolicy(),
    this.importBatchSize = 200,
  }) : assert(importBatchSize > 0);

  /// DNS gateway used for records and mutations.
  final CloudflareDnsGateway gateway;

  /// Public DNS checker. A default instance is created when omitted.
  final DnsDiagnostics? diagnostics;

  /// Preferred zone selected after loading.
  final String? initialZoneName;

  /// Dashboard content padding.
  final EdgeInsetsGeometry padding;

  /// How often a saved record is looked up on public resolvers until every
  /// resolver returns it.
  final Duration propagationCheckInterval;

  /// How long a saved record is watched before it shows as not propagated.
  final Duration propagationTimeout;

  /// Most DNS-only records the automatic health check looks up, apex records
  /// first. Larger zones get a `check_limited` info issue; "Compare
  /// resolvers" still checks every record.
  final int maxHealthCheckRecords;

  /// Plan limits the editor and zone file import validate against. Use
  /// [DnsRecordPolicy.enterprise] for Enterprise zones.
  final DnsRecordPolicy recordPolicy;

  /// Most records a zone file import sends in one batch request, when the
  /// gateway is a [BatchCapableGateway]. Cloudflare allows 200 per batch on
  /// Free plans and 3,500 on paid plans. Each batch is atomic, but an import
  /// split into several batches is not: earlier batches stay applied when a
  /// later one fails.
  final int importBatchSize;

  @override
  State<CloudflareDnsDashboard> createState() => _CloudflareDnsDashboardState();
}

class _CloudflareDnsDashboardState extends State<CloudflareDnsDashboard> {
  List<DnsZone> _zones = const <DnsZone>[];
  List<DnsRecord> _records = const <DnsRecord>[];
  DnsZone? _selectedZone;
  DnsHealthReport? _report;
  _RecordFilter _filter = _RecordFilter.all;
  final _search = TextEditingController();
  String _query = '';
  Timer? _searchDebounce;
  bool _comparing = false;
  bool _loading = true;
  bool _writing = false;
  bool _checking = false;
  String? _error;
  String? _healthError;
  final _propagation = <String, DnsPropagationStatus>{};
  // Deleted records being watched until public resolvers drop them.
  final _removals =
      <String, ({DnsRecord record, DnsPropagationStatus status})>{};
  final _watches = <String, StreamSubscription<DnsResolverComparison>>{};

  DnsDiagnostics? _ownedDiagnostics;

  DnsDiagnostics get _diagnostics =>
      widget.diagnostics ?? (_ownedDiagnostics ??= DnsDiagnostics());

  @override
  void initState() {
    super.initState();
    _loadZones();
  }

  @override
  void dispose() {
    _stopWatches();
    _searchDebounce?.cancel();
    _ownedDiagnostics?.close();
    _search.dispose();
    super.dispose();
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
      // Apex records first: they matter most when the check is capped.
      final candidates =
          _records.where((record) => record.proxied != true).toList()..sort(
            (a, b) =>
                (_isApex(a, zone) ? 0 : 1).compareTo(_isApex(b, zone) ? 0 : 1),
          );
      final expected = candidates.take(widget.maxHealthCheckRecords).toList();
      final report = await _diagnostics.check(
        zone.name,
        types: const <DnsRecordType>[],
        expectedRecords: expected,
      );
      final skipped = candidates.length - expected.length;
      if (mounted) {
        setState(
          () => _report = skipped <= 0
              ? report
              : DnsHealthReport(
                  domain: report.domain,
                  checkedAt: report.checkedAt,
                  answers: report.answers,
                  issues: <DnsIssue>[
                    ...report.issues,
                    DnsIssue(
                      code: 'check_limited',
                      message:
                          'Checked ${expected.length} of '
                          '${candidates.length} DNS-only records.',
                      severity: DnsIssueSeverity.info,
                    ),
                  ],
                ),
        );
      }
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
      isScrollControlled: true,
      builder: (context) =>
          _ZonePickerSheet(zones: _zones, selected: _selectedZone),
    );
    if (selected == null || selected == _selectedZone || !mounted) return;
    _stopWatches();
    setState(() {
      _selectedZone = selected;
      _propagation.clear();
      _removals.clear();
      _filter = _RecordFilter.all;
      _search.clear();
      _query = '';
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
      existingRecords: _records,
      policy: widget.recordPolicy,
    );
    if (record == null || !mounted) return;
    setState(() => _writing = true);
    try {
      final saved = initial?.id == null
          ? await widget.gateway.createRecord(zone.id, record)
          : await widget.gateway.updateRecord(zone.id, initial!.id!, record);
      _watchPropagation(saved, zone);
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
      _watchPropagation(record, zone, removal: true);
      await _loadRecords();
    } on Object catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _writing = false);
    }
  }

  /// Polls public resolvers for [record] and tracks it in [_propagation], or
  /// with [removal], in [_removals] until resolvers no longer return it.
  void _watchPropagation(
    DnsRecord record,
    DnsZone zone, {
    bool removal = false,
  }) {
    // Proxied records answer with Cloudflare's addresses, never their own,
    // and an apex CNAME is flattened into the target's A and AAAA records.
    if (record.proxied == true || !mounted) return;
    if (record.type == DnsRecordType.cname && _isApex(record, zone)) return;
    final key = '${removal ? 'removed:' : ''}${dnsPropagationKey(record)}';
    _watches.remove(key)?.cancel();
    final name = record.name.trim();
    final fqdn = name.isEmpty || name == '@'
        ? zone.name
        : name == zone.name || name.endsWith('.${zone.name}')
        ? name
        : '$name.${zone.name}';
    final watched = record.copyWith(name: fqdn);
    void update(DnsPropagationStatus status) {
      if (removal) {
        _removals[key] = (record: watched, status: status);
      } else {
        _propagation[key] = status;
      }
    }

    DnsPropagationStatus? current() =>
        removal ? _removals[key]?.status : _propagation[key];

    setState(() => update(DnsPropagationStatus.propagating));
    _watches[key] = _diagnostics
        .watchPropagation(
          watched,
          interval: widget.propagationCheckInterval,
          timeout: widget.propagationTimeout,
          removal: removal,
        )
        .listen(
          (comparison) {
            final done = removal
                ? comparison.lacks(watched)
                : comparison.matches(watched);
            if (mounted && done) {
              setState(() => update(DnsPropagationStatus.propagated));
            }
          },
          onError: (Object _) {},
          onDone: () {
            _watches.remove(key);
            if (mounted && current() == DnsPropagationStatus.propagating) {
              setState(() => update(DnsPropagationStatus.timedOut));
            }
          },
        );
  }

  void _clearFinishedRemovals() => _removals.removeWhere(
    (_, removal) => removal.status != DnsPropagationStatus.propagating,
  );

  void _stopWatches() {
    for (final watch in _watches.values) {
      watch.cancel();
    }
    _watches.clear();
  }

  Future<void> _exportZone() async {
    final zone = _selectedZone;
    if (zone == null) return;
    await Clipboard.setData(
      ClipboardData(text: DnsZoneFile.encode(_records, origin: zone.name)),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Zone file with ${_records.length} records copied'),
      ),
    );
  }

  Future<void> _importZone() async {
    final zone = _selectedZone;
    if (zone == null || _writing) return;
    final records = await DnsZoneImportSheet.show(
      context,
      zoneName: zone.name,
      existingRecords: _records,
      policy: widget.recordPolicy,
    );
    if (records == null || records.isEmpty || !mounted) return;
    setState(() => _writing = true);
    final gateway = widget.gateway;
    var imported = 0;
    final failures = <({DnsRecord record, String message})>[];
    try {
      if (gateway is BatchCapableGateway) {
        // Each batch is atomic: either all of its records are created or
        // none is. Stop at the first failed batch.
        for (
          var start = 0;
          start < records.length;
          start += widget.importBatchSize
        ) {
          final chunk = records.sublist(
            start,
            (start + widget.importBatchSize).clamp(0, records.length),
          );
          try {
            imported += (await gateway.batch(
              zone.id,
              posts: chunk,
            )).posts.length;
          } on Object catch (error) {
            final message = _safeMessage(error);
            failures.addAll(<({DnsRecord record, String message})>[
              for (final record in chunk) (record: record, message: message),
              for (final record in records.skip(start + chunk.length))
                (
                  record: record,
                  message: 'Not sent after an earlier batch failed.',
                ),
            ]);
            break;
          }
        }
      } else {
        for (final record in records) {
          try {
            await gateway.createRecord(zone.id, record);
            imported++;
          } on Object catch (error) {
            failures.add((record: record, message: _safeMessage(error)));
          }
        }
      }
      if (imported > 0) await _loadRecords();
    } finally {
      if (mounted) setState(() => _writing = false);
    }
    if (!mounted) return;
    if (failures.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Imported $imported records')));
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => _ImportResultSheet(
        imported: imported,
        total: records.length,
        failures: failures,
      ),
    );
  }

  Future<void> _compareResolvers() async {
    final expected = _records
        .where((record) => record.proxied != true)
        .toList(growable: false);
    if (expected.isEmpty || _comparing) return;
    setState(() => _comparing = true);
    List<DnsResolverComparison>? comparisons;
    try {
      comparisons = await _diagnostics.compareResolvers(expected);
    } on Object catch (error) {
      if (mounted) _showError(error);
    } finally {
      // Stop the button spinner before the sheet opens, not after it closes.
      if (mounted) setState(() => _comparing = false);
    }
    if (comparisons == null || !mounted) return;
    final results = comparisons;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => _ResolverComparisonSheet(comparisons: results),
    );
  }

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _query = value.trim().toLowerCase());
    });
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
    final query = _query;
    final padding = widget.padding.resolve(Directionality.of(context));
    final visibleRecords = _records
        .where(
          (record) =>
              _filter.includes(record) &&
              (query.isEmpty ||
                  record.name.toLowerCase().contains(query) ||
                  record.content.toLowerCase().contains(query)),
        )
        .toList(growable: false);

    return Stack(
      children: <Widget>[
        ColoredBox(
          color: colors.surface,
          child: RefreshIndicator(
            edgeOffset: 96,
            onRefresh: _selectedZone == null ? _loadZones : _loadRecords,
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Centers the record list under the 760 px header column.
                final inset = ((constraints.maxWidth - _maxWidth) / 2).clamp(
                  0.0,
                  double.infinity,
                );
                return CustomScrollView(
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
                        MenuAnchor(
                          builder: (context, controller, child) => IconButton(
                            tooltip: 'Zone file',
                            onPressed: _selectedZone == null || _writing
                                ? null
                                : () => controller.isOpen
                                      ? controller.close()
                                      : controller.open(),
                            icon: const Icon(Icons.description_outlined),
                          ),
                          menuChildren: <Widget>[
                            MenuItemButton(
                              onPressed: _records.isEmpty ? null : _exportZone,
                              leadingIcon: const Icon(
                                Icons.content_copy_rounded,
                              ),
                              child: const Text('Export zone file'),
                            ),
                            MenuItemButton(
                              onPressed: _importZone,
                              leadingIcon: const Icon(
                                Icons.upload_file_rounded,
                              ),
                              child: const Text('Import zone file'),
                            ),
                          ],
                        ),
                        const SizedBox(width: 4),
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
                          constraints: const BoxConstraints(
                            maxWidth: _maxWidth,
                          ),
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              padding.left,
                              padding.top,
                              padding.right,
                              0,
                            ),
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
                                if (_selectedZone != null) ...<Widget>[
                                  const SizedBox(height: 10),
                                  Align(
                                    alignment: AlignmentDirectional.centerEnd,
                                    child: FilledButton.tonalIcon(
                                      onPressed: _comparing || _records.isEmpty
                                          ? null
                                          : _compareResolvers,
                                      icon: _comparing
                                          ? const SizedBox.square(
                                              dimension: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : const Icon(
                                              Icons.compare_arrows_rounded,
                                            ),
                                      label: const Text('Compare resolvers'),
                                    ),
                                  ),
                                ],
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
                                SearchBar(
                                  controller: _search,
                                  hintText: 'Search name or value',
                                  leading: const Icon(Icons.search_rounded),
                                  elevation:
                                      const WidgetStatePropertyAll<double>(0),
                                  onChanged: _onSearchChanged,
                                  trailing: <Widget>[
                                    if (_search.text.isNotEmpty)
                                      IconButton(
                                        tooltip: 'Clear search',
                                        onPressed: () {
                                          _searchDebounce?.cancel();
                                          setState(() {
                                            _search.clear();
                                            _query = '';
                                          });
                                        },
                                        icon: const Icon(Icons.close_rounded),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                _RecordFilterBar(
                                  selected: _filter,
                                  onSelected: (filter) {
                                    setState(() => _filter = filter);
                                  },
                                ),
                                const SizedBox(height: 14),
                                if (_removals.isNotEmpty) ...<Widget>[
                                  _RemovalList(
                                    removals: _removals.values.toList(
                                      growable: false,
                                    ),
                                    onDismiss: () =>
                                        setState(_clearFinishedRemovals),
                                  ),
                                  const SizedBox(height: 14),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    // A sliver, so only the visible records are built.
                    SliverPadding(
                      padding: EdgeInsets.fromLTRB(
                        inset + padding.left,
                        0,
                        inset + padding.right,
                        padding.bottom,
                      ),
                      sliver: DnsRecordList.sliver(
                        records: visibleRecords,
                        enabled: !_writing,
                        propagation: Map.unmodifiable(_propagation),
                        onEdit: _edit,
                        onDelete: _delete,
                        // Round-tripping through the API JSON drops the id, so
                        // the editor saves it as a new record.
                        onDuplicate: (record) => _edit(
                          DnsRecord.fromJson(record.toCloudflareJson()),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        PositionedDirectional(
          end: 20,
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

const double _maxWidth = 760;

bool _isApex(DnsRecord record, DnsZone zone) {
  final name = record.name.trim().toLowerCase().replaceFirst(
    RegExp(r'\.$'),
    '',
  );
  return name.isEmpty || name == '@' || name == zone.name.toLowerCase();
}

class _ZonePickerSheet extends StatefulWidget {
  const _ZonePickerSheet({required this.zones, required this.selected});

  final List<DnsZone> zones;
  final DnsZone? selected;

  @override
  State<_ZonePickerSheet> createState() => _ZonePickerSheetState();
}

class _ZonePickerSheetState extends State<_ZonePickerSheet> {
  /// Zone counts above this get a search field.
  static const _searchThreshold = 8;

  String _query = '';

  @override
  Widget build(BuildContext context) {
    final zones = _query.isEmpty
        ? widget.zones
        : widget.zones
              .where((zone) => zone.name.toLowerCase().contains(_query))
              .toList(growable: false);
    return Padding(
      // Keep the search field above the keyboard.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: SafeArea(
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
                if (widget.zones.length > _searchThreshold)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                    child: SearchBar(
                      hintText: 'Search zones',
                      leading: const Icon(Icons.search_rounded),
                      elevation: const WidgetStatePropertyAll<double>(0),
                      onChanged: (value) =>
                          setState(() => _query = value.trim().toLowerCase()),
                    ),
                  ),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: zones.length,
                    itemBuilder: (context, index) {
                      final zone = zones[index];
                      return ListTile(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(18),
                        ),
                        leading: CircleAvatar(
                          child: Text(zone.name.characters.first.toUpperCase()),
                        ),
                        title: Text(zone.name),
                        subtitle: Text(zone.status ?? 'unknown'),
                        trailing: zone == widget.selected
                            ? const Icon(Icons.check_circle_rounded)
                            : null,
                        selected: zone == widget.selected,
                        onTap: () => Navigator.pop(context, zone),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ResolverComparisonSheet extends StatelessWidget {
  const _ResolverComparisonSheet({required this.comparisons});

  final List<DnsResolverComparison> comparisons;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final differing = comparisons.where((c) => !c.consistent).length;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: <Widget>[
        Text(
          'Resolver comparison',
          style: textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 4),
        Text(
          differing == 0
              ? 'Cloudflare and Google return the same answers.'
              : '$differing of ${comparisons.length} records differ between '
                    'resolvers.',
          style: textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        for (final comparison in comparisons)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              comparison.consistent
                  ? Icons.check_circle_rounded
                  : Icons.warning_amber_rounded,
              color: comparison.consistent ? colors.primary : colors.error,
            ),
            title: Text('${comparison.type.wireName} ${comparison.name}'),
            subtitle: Text(
              <String>[
                for (final entry in comparison.answers.entries)
                  '${entry.key}: ${comparison.failedResolvers.contains(entry.key)
                      ? 'lookup failed'
                      : comparison.nxdomainResolvers.contains(entry.key)
                      ? 'name does not exist'
                      : entry.value.isEmpty
                      ? 'no answer'
                      : <String>[for (final cname in comparison.cnames[entry.key] ?? const <DnsRecord>[]) '→ ${cname.content}', entry.value.map((r) => r.content).join(', ')].join(' ')}',
              ].join('\n'),
            ),
            isThreeLine: comparison.answers.length > 1,
          ),
      ],
    );
  }
}

/// Per-record results of a zone file import that did not fully succeed.
class _ImportResultSheet extends StatelessWidget {
  const _ImportResultSheet({
    required this.imported,
    required this.total,
    required this.failures,
  });

  final int imported;
  final int total;
  final List<({DnsRecord record, String message})> failures;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      itemCount: failures.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Imported $imported of $total records',
                  style: textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${failures.length} records were not created.',
                  style: textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
        }
        final failure = failures[index - 1];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.error_outline_rounded, color: colors.error),
          title: Text(
            '${failure.record.type.wireName} ${failure.record.name}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(failure.message),
        );
      },
    );
  }
}

/// Deleted records still being watched on public resolvers.
class _RemovalList extends StatelessWidget {
  const _RemovalList({required this.removals, required this.onDismiss});

  final List<({DnsRecord record, DnsPropagationStatus status})> removals;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final finished = removals.any(
      (removal) => removal.status != DnsPropagationStatus.propagating,
    );
    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Deleted records',
                    style: textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (finished)
                  TextButton(onPressed: onDismiss, child: const Text('Clear')),
              ],
            ),
            for (final removal in removals)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: <Widget>[
                    DnsSyncStatusIcon(
                      active:
                          removal.status == DnsPropagationStatus.propagating,
                      icon: switch (removal.status) {
                        DnsPropagationStatus.propagating => Icons.sync_rounded,
                        DnsPropagationStatus.propagated =>
                          Icons.check_circle_rounded,
                        DnsPropagationStatus.timedOut =>
                          Icons.warning_amber_rounded,
                      },
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${removal.record.type.wireName} '
                        '${removal.record.name}: ${switch (removal.status) {
                          DnsPropagationStatus.propagating => 'removing from public DNS',
                          DnsPropagationStatus.propagated => 'gone from public DNS',
                          DnsPropagationStatus.timedOut => 'still visible on some resolvers',
                        }}',
                        style: textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
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
        borderRadius: const BorderRadiusDirectional.only(
          topStart: Radius.circular(16),
          topEnd: Radius.circular(16),
          bottomStart: Radius.circular(16),
          bottomEnd: Radius.circular(6),
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
          padding: const EdgeInsetsDirectional.fromSTEB(18, 16, 14, 16),
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
          record.type == DnsRecordType.cname ||
          record.type == DnsRecordType.https ||
          record.type == DnsRecordType.svcb,
    _RecordFilter.verification => record.type == DnsRecordType.txt,
    _RecordFilter.service => record.type == DnsRecordType.srv,
    _RecordFilter.mail => record.type == DnsRecordType.mx,
    _RecordFilter.infrastructure =>
      record.type == DnsRecordType.ns ||
          record.type == DnsRecordType.caa ||
          record.type == DnsRecordType.ptr,
  };
}

String _safeMessage(Object error) {
  if (error is CloudflareDnsException) return error.message;
  return 'An unexpected DNS error occurred.';
}
