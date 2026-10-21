import 'package:flutter/material.dart';

import '../models/dns_health.dart';
import 'dns_sync_status_icon.dart';

/// Material card summarizing a [DnsHealthReport].
class DomainHealthCard extends StatelessWidget {
  /// Creates a health card.
  const DomainHealthCard({
    super.key,
    required this.domain,
    this.report,
    this.loading = false,
    this.error,
    this.onRefresh,
  });

  /// Displayed domain name.
  final String domain;

  /// Latest report.
  final DnsHealthReport? report;

  /// Whether a health check is running.
  final bool loading;

  /// Safe error message.
  final String? error;

  /// Refresh callback.
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final currentReport = report;
    final hasError = error != null || (report?.errorCount ?? 0) > 0;
    final hasWarnings =
        report?.issues.any(
          (issue) => issue.severity == DnsIssueSeverity.warning,
        ) ??
        false;
    final containerColor = hasError
        ? colors.errorContainer
        : hasWarnings
        ? colors.secondaryContainer
        : colors.tertiaryContainer;
    final foregroundColor = hasError
        ? colors.onErrorContainer
        : hasWarnings
        ? colors.onSecondaryContainer
        : colors.onTertiaryContainer;
    final icon = hasError
        ? Icons.error_outline_rounded
        : hasWarnings
        ? Icons.warning_amber_rounded
        : Icons.check_circle_rounded;
    final label = loading
        ? 'Checking public DNS…'
        : error ??
              (hasError
                  ? 'DNS check found errors'
                  : hasWarnings
                  ? 'DNS check found warnings'
                  : report == null
                  ? 'DNS check not run'
                  : 'Public DNS is healthy');
    final details = loading
        ? ClipRRect(
            key: const ValueKey<String>('health-check-progress'),
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              color: foregroundColor,
              backgroundColor: foregroundColor.withValues(alpha: 0.16),
            ),
          )
        : currentReport != null && currentReport.issues.isEmpty
        ? _SupportingMessage(
            key: const ValueKey<String>('health-check-healthy'),
            icon: Icons.travel_explore_rounded,
            message: 'Public resolvers match your DNS configuration',
            color: foregroundColor,
          )
        : currentReport != null && currentReport.issues.isNotEmpty
        ? Column(
            key: const ValueKey<String>('health-check-issues'),
            children: <Widget>[
              for (final issue in _bySeverity(currentReport.issues).take(4))
                Padding(
                  padding: const EdgeInsets.only(top: 7),
                  child: _SupportingMessage(
                    icon: Icons.info_outline_rounded,
                    message: '• ${issue.message}',
                    color: foregroundColor,
                  ),
                ),
            ],
          )
        : const SizedBox.shrink(key: ValueKey<String>('health-check-empty'));

    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: containerColor,
        borderRadius: const BorderRadiusDirectional.only(
          topStart: Radius.circular(32),
          topEnd: Radius.circular(32),
          bottomStart: Radius.circular(32),
          bottomEnd: Radius.circular(10),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              // Expanded rather than a Spacer, so large text wraps instead of
              // overflowing.
              Expanded(
                child: Text(
                  'PUBLIC DNS',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: foregroundColor.withValues(alpha: 0.78),
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                  ),
                ),
              ),
              if (onRefresh != null)
                IconButton(
                  tooltip: 'Refresh DNS health',
                  onPressed: loading ? null : onRefresh,
                  style: IconButton.styleFrom(
                    foregroundColor: foregroundColor,
                    backgroundColor: foregroundColor.withValues(alpha: 0.08),
                  ),
                  icon: DnsSyncStatusIcon(active: loading),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: foregroundColor,
                  shape: BoxShape.circle,
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween<double>(
                        begin: 0.84,
                        end: 1,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: loading
                      ? DnsSyncStatusIcon(
                          key: const ValueKey<String>('health-status-syncing'),
                          active: true,
                          icon: Icons.sync_rounded,
                          size: 31,
                          color: containerColor,
                        )
                      : Icon(
                          icon,
                          key: ValueKey<IconData>(icon),
                          color: containerColor,
                          size: 31,
                        ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      layoutBuilder: (currentChild, previousChildren) =>
                          currentChild ?? const SizedBox.shrink(),
                      child: Text(
                        label,
                        key: ValueKey<String>(label),
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(
                              color: foregroundColor,
                              fontWeight: FontWeight.w800,
                              height: 1.15,
                            ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      domain,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: foregroundColor.withValues(alpha: 0.78),
                      ),
                    ),
                    if (!loading && currentReport?.dnssecValidated != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: _DnssecLabel(
                          validated: currentReport!.dnssecValidated!,
                          color: foregroundColor,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            child: Padding(
              padding: EdgeInsets.only(
                top: details is SizedBox
                    ? 0
                    : loading
                    ? 20
                    : 18,
              ),
              child: details,
            ),
          ),
        ],
      ),
    );
  }
}

class _SupportingMessage extends StatelessWidget {
  const _SupportingMessage({
    super.key,
    required this.icon,
    required this.message,
    required this.color,
  });

  final IconData icon;
  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      children: <Widget>[
        Icon(icon, color: color, size: 19),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            message,
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
}

/// Whether public answers were DNSSEC-validated.
class _DnssecLabel extends StatelessWidget {
  const _DnssecLabel({required this.validated, required this.color});

  final bool validated;
  final Color color;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Icon(
        validated ? Icons.verified_user_rounded : Icons.gpp_maybe_outlined,
        size: 16,
        color: color,
      ),
      const SizedBox(width: 6),
      Flexible(
        child: Text(
          validated ? 'DNSSEC validated' : 'DNSSEC not validated',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ],
  );
}

/// Errors first, then warnings, then info, keeping the order within each.
List<DnsIssue> _bySeverity(List<DnsIssue> issues) => <DnsIssue>[
  for (final severity in DnsIssueSeverity.values.reversed)
    ...issues.where((issue) => issue.severity == severity),
];
