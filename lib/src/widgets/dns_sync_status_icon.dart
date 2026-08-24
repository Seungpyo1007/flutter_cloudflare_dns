import 'dart:async';

import 'package:flutter/material.dart';

/// A refresh glyph that communicates active work and settles before completion.
///
/// Kept internal to the package widgets so refresh actions share the same motion
/// language without exposing animation state through the public API.
class DnsSyncStatusIcon extends StatefulWidget {
  const DnsSyncStatusIcon({
    super.key,
    required this.active,
    this.icon = Icons.sync_rounded,
    this.size,
    this.color,
  });

  final bool active;
  final IconData icon;
  final double? size;
  final Color? color;

  @override
  State<DnsSyncStatusIcon> createState() => _DnsSyncStatusIconState();
}

class _DnsSyncStatusIconState extends State<DnsSyncStatusIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _turns;
  Timer? _completionTimer;
  bool _showComplete = false;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _turns = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 880),
    );
    if (widget.active) _turns.repeat();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (reduceMotion == _reduceMotion) return;
    _reduceMotion = reduceMotion;
    if (_reduceMotion) {
      _turns.stop();
      _turns.value = 0;
    } else if (widget.active) {
      _turns.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant DnsSyncStatusIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active) return;
    _completionTimer?.cancel();

    if (widget.active) {
      setState(() => _showComplete = false);
      if (!_reduceMotion) {
        _turns.value = 0;
        _turns.repeat();
      }
      return;
    }

    if (_reduceMotion) {
      _showCompletion();
      return;
    }

    final remaining = 1 - _turns.value;
    _turns
        .animateTo(
          1,
          duration: Duration(milliseconds: (160 + 300 * remaining).round()),
          curve: Curves.easeOutCubic,
        )
        .whenComplete(_showCompletion);
  }

  void _showCompletion() {
    if (!mounted || widget.active) return;
    _turns.value = 0;
    setState(() => _showComplete = true);
    _completionTimer = Timer(const Duration(milliseconds: 720), () {
      if (mounted && !widget.active) setState(() => _showComplete = false);
    });
  }

  @override
  void dispose() {
    _completionTimer?.cancel();
    _turns.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final duration = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 180);
    final status = widget.active
        ? 'Syncing'
        : _showComplete
        ? 'Sync complete'
        : 'Ready to sync';

    return Semantics(
      label: status,
      liveRegion: widget.active || _showComplete,
      child: ExcludeSemantics(
        child: AnimatedSwitcher(
          duration: duration,
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.82, end: 1).animate(animation),
              child: child,
            ),
          ),
          child: _showComplete
              ? Icon(
                  Icons.check_rounded,
                  key: const ValueKey<String>('sync-complete'),
                  size: widget.size,
                  color: widget.color,
                )
              : RotationTransition(
                  key: const ValueKey<String>('sync-refresh'),
                  turns: _turns,
                  child: Icon(
                    widget.icon,
                    size: widget.size,
                    color: widget.color,
                  ),
                ),
        ),
      ),
    );
  }
}
