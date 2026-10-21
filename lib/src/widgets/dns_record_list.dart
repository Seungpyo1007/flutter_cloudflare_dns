import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/dns_name.dart';
import '../models/dns_record.dart';
import 'dns_sync_status_icon.dart';

/// Whether a saved record is visible on public resolvers yet.
enum DnsPropagationStatus {
  /// Resolvers are being polled and do not all return the record yet.
  propagating,

  /// Every resolver returns the record.
  propagated,

  /// Polling stopped before every resolver returned the record.
  timedOut,
}

/// The key [DnsRecordList.propagation] uses for [record]: its id, or
/// `name|TYPE` when it has none.
String dnsPropagationKey(DnsRecord record) =>
    record.id ?? '${record.name}|${record.type.wireName}';

/// Responsive Material list of DNS records.
///
/// Tiles are built lazily when the list has a bounded height, and by
/// [DnsRecordList.sliver] inside a [CustomScrollView], so zones with
/// thousands of records stay fast. With an unbounded height, such as in a
/// [Column] inside a scroll view, every tile is built.
class DnsRecordList extends StatelessWidget {
  /// Creates a record list.
  const DnsRecordList({
    super.key,
    required this.records,
    this.onEdit,
    this.onDelete,
    this.onDuplicate,
    this.enabled = true,
    this.propagation = const <String, DnsPropagationStatus>{},
  }) : _sliver = false;

  /// Creates a record list for a [CustomScrollView]'s slivers.
  const DnsRecordList.sliver({
    super.key,
    required this.records,
    this.onEdit,
    this.onDelete,
    this.onDuplicate,
    this.enabled = true,
    this.propagation = const <String, DnsPropagationStatus>{},
  }) : _sliver = true;

  /// Records to display.
  final List<DnsRecord> records;

  /// Edit callback.
  final ValueChanged<DnsRecord>? onEdit;

  /// Delete callback.
  final ValueChanged<DnsRecord>? onDelete;

  /// Duplicate callback. The menu item is disabled when null.
  final ValueChanged<DnsRecord>? onDuplicate;

  /// Whether actions are enabled.
  final bool enabled;

  /// Propagation state shown on records, keyed by [dnsPropagationKey].
  final Map<String, DnsPropagationStatus> propagation;

  final bool _sliver;

  static const _radius = Radius.circular(28);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (records.isEmpty) {
      final empty = Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 42),
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: const BorderRadius.all(_radius),
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
      return _sliver ? SliverToBoxAdapter(child: empty) : empty;
    }

    if (_sliver) {
      return DecoratedSliver(
        decoration: BoxDecoration(
          color: colors.surfaceContainerLow,
          borderRadius: const BorderRadius.all(_radius),
        ),
        sliver: SliverList.builder(
          itemCount: records.length,
          itemBuilder: _item,
        ),
      );
    }

    return Material(
      color: colors.surfaceContainerLow,
      borderRadius: const BorderRadius.all(_radius),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) => constraints.hasBoundedHeight
            ? ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: records.length,
                itemBuilder: _item,
              )
            : Column(
                children: <Widget>[
                  for (var index = 0; index < records.length; index++)
                    _item(context, index),
                ],
              ),
      ),
    );
  }

  /// The tile for record [index], with the divider below it.
  Widget _item(BuildContext context, int index) {
    final last = index == records.length - 1;
    final tile = _DnsRecordTile(
      record: records[index],
      enabled: enabled,
      onEdit: onEdit,
      onDelete: onDelete,
      onDuplicate: onDuplicate,
      propagation: propagation[dnsPropagationKey(records[index])],
    );
    final child = last
        ? tile
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              tile,
              const Divider(height: 1, indent: 82, endIndent: 18),
            ],
          );
    if (!_sliver) return child;
    // A sliver cannot clip its children, so round the ink of the end tiles.
    return Material(
      type: MaterialType.transparency,
      borderRadius: BorderRadius.vertical(
        top: index == 0 ? _radius : Radius.zero,
        bottom: last ? _radius : Radius.zero,
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _DnsRecordTile extends StatelessWidget {
  const _DnsRecordTile({
    required this.record,
    required this.enabled,
    required this.onEdit,
    required this.onDelete,
    required this.onDuplicate,
    required this.propagation,
  });

  final DnsRecord record;
  final bool enabled;
  final ValueChanged<DnsRecord>? onEdit;
  final ValueChanged<DnsRecord>? onDelete;
  final ValueChanged<DnsRecord>? onDuplicate;
  final DnsPropagationStatus? propagation;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accent = _typeColor(record.type, colors);
    final content = switch (record.type) {
      DnsRecordType.srv =>
        '${DnsName.toUnicode(record.target ?? '')}:${record.port}',
      DnsRecordType.caa => '${record.caaTag} ${record.caaValue}',
      DnsRecordType.https || DnsRecordType.svcb =>
        '${DnsName.toUnicode(record.target ?? '')} ${record.svcParams ?? ''}'
            .trim(),
      DnsRecordType.cname ||
      DnsRecordType.mx ||
      DnsRecordType.ns ||
      DnsRecordType.ptr => DnsName.toUnicode(record.content),
      DnsRecordType.a ||
      DnsRecordType.aaaa ||
      DnsRecordType.txt => record.content,
    };
    // Internationalized names show in Unicode, with the Punycode form the
    // API uses as a label.
    final displayName = DnsName.toUnicode(record.name);
    final punycode = DnsName.toAscii(record.name);

    return InkWell(
      onTap: enabled && onEdit != null ? () => onEdit!(record) : null,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 8, 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Container(
              width: 50,
              height: 50,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: accent.container,
                borderRadius: const BorderRadiusDirectional.only(
                  topStart: Radius.circular(18),
                  topEnd: Radius.circular(18),
                  bottomStart: Radius.circular(18),
                  bottomEnd: Radius.circular(6),
                ),
              ),
              child: Text(
                record.type.wireName,
                style: TextStyle(
                  color: accent.foreground,
                  fontSize: record.type.wireName.length > 4 ? 10 : 12,
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
                    displayName,
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
                      if (record.type == DnsRecordType.https ||
                          record.type == DnsRecordType.svcb)
                        _MetadataLabel(
                          icon: Icons.low_priority_rounded,
                          label: record.priority == 0
                              ? 'Alias'
                              : 'Priority ${record.priority}',
                        ),
                      if (propagation != null)
                        _PropagationLabel(status: propagation!),
                      if (displayName != punycode)
                        _MetadataLabel(
                          icon: Icons.translate_rounded,
                          label: punycode,
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
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: record.content));
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      const SnackBar(content: Text('Record value copied')),
                    );
                  },
                  leadingIcon: const Icon(Icons.content_copy_rounded),
                  child: const Text('Copy value'),
                ),
                MenuItemButton(
                  onPressed: onDuplicate == null
                      ? null
                      : () => onDuplicate!(record),
                  leadingIcon: const Icon(
                    Icons.control_point_duplicate_rounded,
                  ),
                  child: const Text('Duplicate'),
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

class _PropagationLabel extends StatelessWidget {
  const _PropagationLabel({required this.status});

  final DnsPropagationStatus status;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (label, foreground, background) = switch (status) {
      DnsPropagationStatus.propagating => (
        'Propagating',
        colors.onSurfaceVariant,
        colors.surfaceContainerHighest,
      ),
      DnsPropagationStatus.propagated => (
        'Propagated',
        colors.primary,
        colors.primaryContainer,
      ),
      DnsPropagationStatus.timedOut => (
        'Not visible everywhere yet',
        colors.onErrorContainer,
        colors.errorContainer,
      ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          DnsSyncStatusIcon(
            active: status == DnsPropagationStatus.propagating,
            icon: status == DnsPropagationStatus.timedOut
                ? Icons.schedule_rounded
                : Icons.public_rounded,
            size: 14,
            color: foreground,
          ),
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
          // Long tags or names shorten instead of overflowing the row.
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: foreground,
                fontWeight: FontWeight.w700,
              ),
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
  DnsRecordType.ns || DnsRecordType.ptr => (
    container: colors.surfaceContainerHighest,
    foreground: colors.onSurfaceVariant,
  ),
  DnsRecordType.https || DnsRecordType.svcb => (
    container: colors.secondaryContainer,
    foreground: colors.onSecondaryContainer,
  ),
};
