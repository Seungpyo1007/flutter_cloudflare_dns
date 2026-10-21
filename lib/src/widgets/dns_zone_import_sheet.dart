import 'package:flutter/material.dart';

import '../models/dns_record.dart';
import '../models/dns_zone_file.dart';
import '../validation/dns_record_validator.dart';

/// Material bottom sheet that previews a pasted zone file before import.
///
/// Records that fail validation, already exist in [existingRecords], or
/// conflict with other records (a CNAME next to other records with the same
/// name, a second MX beside a null MX) are shown but not returned.
class DnsZoneImportSheet extends StatefulWidget {
  /// Creates an import sheet.
  const DnsZoneImportSheet({
    super.key,
    required this.zoneName,
    this.existingRecords = const <DnsRecord>[],
    this.policy = const DnsRecordPolicy(),
  });

  /// Zone that relative names resolve against.
  final String zoneName;

  /// Records already in the zone, skipped as duplicates.
  final List<DnsRecord> existingRecords;

  /// Plan limits records are validated against, such as the TTL range.
  final DnsRecordPolicy policy;

  /// Opens the sheet and returns the records to create, or null if cancelled.
  static Future<List<DnsRecord>?> show(
    BuildContext context, {
    required String zoneName,
    List<DnsRecord> existingRecords = const <DnsRecord>[],
    DnsRecordPolicy policy = const DnsRecordPolicy(),
  }) {
    return showModalBottomSheet<List<DnsRecord>>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (_) => DnsZoneImportSheet(
        zoneName: zoneName,
        existingRecords: existingRecords,
        policy: policy,
      ),
    );
  }

  @override
  State<DnsZoneImportSheet> createState() => _DnsZoneImportSheetState();
}

enum _RowStatus { ready, exists, invalid }

typedef _PreviewRow = ({DnsRecord record, _RowStatus status, String? error});

class _DnsZoneImportSheetState extends State<DnsZoneImportSheet> {
  final _text = TextEditingController();
  List<_PreviewRow>? _rows;
  List<DnsZoneFileIssue> _issues = const <DnsZoneFileIssue>[];

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  String _key(DnsRecord record) {
    final zone = widget.zoneName.toLowerCase();
    var name = record.name.trim().toLowerCase().replaceFirst(
      RegExp(r'\.$'),
      '',
    );
    if (name.isEmpty || name == '@') name = zone;
    return '$name|${record.type.wireName}|${record.canonicalContent}';
  }

  void _preview() {
    final result = DnsZoneFile.parse(_text.text, origin: widget.zoneName);
    final existing = widget.existingRecords.map(_key).toSet();
    final seen = <String>{};
    // Zone rules are checked against the zone plus the records accepted so
    // far, so the first of two conflicting records is the one imported.
    final zone = <DnsRecord>[...widget.existingRecords];
    setState(() {
      _issues = result.issues;
      _rows = <_PreviewRow>[
        for (final record in result.records)
          () {
            final issues = DnsRecordValidator.validate(
              record,
              policy: widget.policy,
            );
            if (issues.isNotEmpty) {
              return (
                record: record,
                status: _RowStatus.invalid,
                error: issues.first.message,
              );
            }
            final key = _key(record);
            if (existing.contains(key) || !seen.add(key)) {
              return (record: record, status: _RowStatus.exists, error: null);
            }
            final conflicts = DnsRecordValidator.validateInZone(
              record,
              zone,
              zoneName: widget.zoneName,
            );
            if (conflicts.isNotEmpty) {
              return (
                record: record,
                status: _RowStatus.invalid,
                error: conflicts.first.message,
              );
            }
            zone.add(record);
            return (record: record, status: _RowStatus.ready, error: null);
          }(),
      ];
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    final rows = _rows;
    final ready = rows
        ?.where((row) => row.status == _RowStatus.ready)
        .map((row) => row.record)
        .toList(growable: false);
    int count(_RowStatus status) =>
        rows?.where((row) => row.status == status).length ?? 0;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(24, 4, 24, 24 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            'Import zone file',
            style: textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Relative names resolve against ${widget.zoneName}.',
            style: textTheme.bodyMedium?.copyWith(
              color: colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const ValueKey<String>('zone-file-input'),
            controller: _text,
            minLines: 6,
            maxLines: 12,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: const InputDecoration(
              hintText: 'Paste a BIND zone file, e.g. www 300 IN A 192.0.2.1',
            ),
            onChanged: (_) {
              if (_rows != null) setState(() => _rows = null);
            },
          ),
          const SizedBox(height: 12),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.tonalIcon(
              onPressed: _preview,
              icon: const Icon(Icons.preview_rounded),
              label: const Text('Preview'),
            ),
          ),
          if (rows != null) ...<Widget>[
            const SizedBox(height: 16),
            Text(
              <String>[
                '${count(_RowStatus.ready)} ready',
                if (count(_RowStatus.exists) > 0)
                  '${count(_RowStatus.exists)} already exist',
                if (count(_RowStatus.invalid) > 0)
                  '${count(_RowStatus.invalid)} invalid',
                if (_issues.isNotEmpty) '${_issues.length} lines skipped',
              ].join(' · '),
              style: textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            for (final row in rows)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(
                  switch (row.status) {
                    _RowStatus.ready => Icons.add_circle_outline_rounded,
                    _RowStatus.exists => Icons.check_circle_outline_rounded,
                    _RowStatus.invalid => Icons.error_outline_rounded,
                  },
                  color: row.status == _RowStatus.invalid ? colors.error : null,
                ),
                title: Text(
                  '${row.record.type.wireName} ${row.record.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  switch (row.status) {
                    _RowStatus.ready => row.record.content,
                    _RowStatus.exists => 'Already exists, skipped',
                    _RowStatus.invalid => row.error!,
                  },
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            for (final issue in _issues)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.remove_circle_outline_rounded),
                title: Text('Line ${issue.line}'),
                subtitle: Text(issue.message),
              ),
          ],
          const SizedBox(height: 24),
          Row(
            children: <Widget>[
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: ready == null || ready.isEmpty
                      ? null
                      : () => Navigator.pop(context, ready),
                  icon: const Icon(Icons.upload_rounded),
                  label: Text(
                    ready == null || ready.isEmpty
                        ? 'Import'
                        : 'Import ${ready.length} '
                              '${ready.length == 1 ? 'record' : 'records'}',
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
