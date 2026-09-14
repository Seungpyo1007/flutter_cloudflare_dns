import 'package:flutter/material.dart';

import '../models/dns_record.dart';

/// Responsive Material list of DNS records.
class DnsRecordList extends StatelessWidget {
  /// Creates a record list.
  const DnsRecordList({
    super.key,
    required this.records,
    this.onEdit,
    this.onDelete,
    this.enabled = true,
  });

  /// Records to display.
  final List<DnsRecord> records;

  /// Edit callback.
  final ValueChanged<DnsRecord>? onEdit;

  /// Delete callback.
  final ValueChanged<DnsRecord>? onDelete;

  /// Whether actions are enabled.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (records.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 42),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: BorderRadius.circular(28),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.filter_alt_off_rounded,
              color: colors.onSurfaceVariant,
              size: 32,
            ),
            const SizedBox(height: 12),
            const Text('No supported DNS records found.'),
          ],
        ),
      );
    }

    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          for (var index = 0; index < records.length; index++) ...<Widget>[
            _DnsRecordTile(
              record: records[index],
              enabled: enabled,
              onEdit: onEdit,
              onDelete: onDelete,
            ),
            if (index != records.length - 1)
              const Divider(height: 1, indent: 82, endIndent: 18),
          ],
        ],
      ),
    );
  }
}

class _DnsRecordTile extends StatelessWidget {
  const _DnsRecordTile({
    required this.record,
    required this.enabled,
    required this.onEdit,
    required this.onDelete,
  });

  final DnsRecord record;
  final bool enabled;
  final ValueChanged<DnsRecord>? onEdit;
  final ValueChanged<DnsRecord>? onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accent = _typeColor(record.type, colors);
    final content = switch (record.type) {
      DnsRecordType.srv => '${record.target}:${record.port}',
      DnsRecordType.caa => '${record.caaTag} ${record.caaValue}',
      DnsRecordType.a ||
      DnsRecordType.aaaa ||
      DnsRecordType.cname ||
      DnsRecordType.txt ||
      DnsRecordType.mx ||
      DnsRecordType.ns => record.content,
    };

    return InkWell(
      onTap: enabled && onEdit != null ? () => onEdit!(record) : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              width: 50,
              height: 50,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: accent.container,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                  bottomLeft: Radius.circular(18),
                  bottomRight: Radius.circular(6),
                ),
              ),
              child: Text(
                record.type.wireName,
                style: TextStyle(
                  color: accent.foreground,
                  fontSize: record.type == DnsRecordType.cname ? 10 : 12,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.2,
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    record.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    content,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 11),
                  Wrap(
                    spacing: 7,
                    runSpacing: 7,
                    children: <Widget>[
                      _MetadataLabel(
                        icon: record.proxied == true
                            ? Icons.cloud_rounded
                            : Icons.language_rounded,
                        label: record.proxied == true ? 'Proxied' : 'DNS only',
                        emphasized: record.proxied == true,
                      ),
                      _MetadataLabel(
                        icon: Icons.schedule_rounded,
                        label: record.ttl == 1
                            ? 'Auto TTL'
                            : '${record.ttl}s TTL',
                      ),
                      if (record.type == DnsRecordType.srv)
                        _MetadataLabel(
                          icon: Icons.route_rounded,
                          label:
                              'P${record.priority} · W${record.weight} · ${record.port}',
                        ),
                      if (record.type == DnsRecordType.mx)
                        _MetadataLabel(
                          icon: Icons.low_priority_rounded,
                          label: 'Priority ${record.priority}',
                        ),
                      if (record.tags.isNotEmpty)
                        _MetadataLabel(
                          icon: Icons.sell_outlined,
                          label: record.tags.join(', '),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            MenuAnchor(
              builder: (context, controller, child) => IconButton(
                tooltip: 'Record actions',
                onPressed: enabled
                    ? () => controller.isOpen
                          ? controller.close()
                          : controller.open()
                    : null,
                icon: const Icon(Icons.more_vert_rounded),
              ),
              menuChildren: <Widget>[
                MenuItemButton(
                  onPressed: onEdit == null ? null : () => onEdit!(record),
                  leadingIcon: const Icon(Icons.edit_outlined),
                  child: const Text('Edit'),
                ),
                MenuItemButton(
                  onPressed: onDelete == null ? null : () => onDelete!(record),
                  leadingIcon: const Icon(Icons.delete_outline),
                  child: const Text('Delete'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MetadataLabel extends StatelessWidget {
  const _MetadataLabel({
    required this.icon,
    required this.label,
    this.emphasized = false,
  });

  final IconData icon;
  final String label;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = emphasized ? colors.primary : colors.onSurfaceVariant;
    final background = emphasized
        ? colors.primaryContainer
        : colors.surfaceContainerHighest;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 14, color: foreground),
          const SizedBox(width: 5),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

({Color container, Color foreground}) _typeColor(
  DnsRecordType type,
  ColorScheme colors,
) => switch (type) {
  DnsRecordType.a => (
    container: colors.primaryContainer,
    foreground: colors.onPrimaryContainer,
  ),
  DnsRecordType.aaaa => (
    container: colors.secondaryContainer,
    foreground: colors.onSecondaryContainer,
  ),
  DnsRecordType.cname => (
    container: colors.tertiaryContainer,
    foreground: colors.onTertiaryContainer,
  ),
  DnsRecordType.txt => (
    container: colors.secondaryContainer,
    foreground: colors.onSecondaryContainer,
  ),
  DnsRecordType.srv => (
    container: colors.tertiaryContainer,
    foreground: colors.onTertiaryContainer,
  ),
  DnsRecordType.mx => (
    container: colors.primaryContainer,
    foreground: colors.onPrimaryContainer,
  ),
  DnsRecordType.caa => (
    container: colors.errorContainer,
    foreground: colors.onErrorContainer,
  ),
  DnsRecordType.ns => (
    container: colors.surfaceContainerHighest,
    foreground: colors.onSurfaceVariant,
  ),
};
