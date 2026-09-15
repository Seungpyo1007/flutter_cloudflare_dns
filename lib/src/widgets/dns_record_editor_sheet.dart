import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/dns_record.dart';
import '../validation/dns_record_validator.dart';

/// Material bottom sheet for creating or editing one supported DNS record.
class DnsRecordEditorSheet extends StatefulWidget {
  /// Creates an editor.
  const DnsRecordEditorSheet({
    super.key,
    required this.zoneName,
    this.initialRecord,
  });

  /// Zone used for hints.
  final String zoneName;

  /// Existing record, or null when creating.
  final DnsRecord? initialRecord;

  /// Opens the editor and returns the submitted record.
  static Future<DnsRecord?> show(
    BuildContext context, {
    required String zoneName,
    DnsRecord? initialRecord,
  }) {
    return showModalBottomSheet<DnsRecord>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 720),
      builder: (_) => DnsRecordEditorSheet(
        zoneName: zoneName,
        initialRecord: initialRecord,
      ),
    );
  }

  @override
  State<DnsRecordEditorSheet> createState() => _DnsRecordEditorSheetState();
}

class _DnsRecordEditorSheetState extends State<DnsRecordEditorSheet> {
  static const _presetTtls = <int>{1, 300, 3600};

  final _formKey = GlobalKey<FormState>();
  late DnsRecordType _type;
  late final TextEditingController _name;
  late final TextEditingController _content;
  late final TextEditingController _ttl;
  late final TextEditingController _priority;
  late final TextEditingController _weight;
  late final TextEditingController _port;
  late final TextEditingController _target;
  late final TextEditingController _caaFlags;
  late final TextEditingController _caaValue;
  late final TextEditingController _comment;
  late final TextEditingController _tags;
  late String _caaTag;
  late bool _proxied;
  late bool _ttlCustom;
  String? _formError;

  @override
  void initState() {
    super.initState();
    final record = widget.initialRecord;
    _type = record?.type ?? DnsRecordType.a;
    _name = TextEditingController(text: record?.name ?? '');
    _content = TextEditingController(text: record?.content ?? '');
    _ttl = TextEditingController(text: '${record?.ttl ?? 1}');
    _priority = TextEditingController(text: '${record?.priority ?? 0}');
    _weight = TextEditingController(text: '${record?.weight ?? 0}');
    _port = TextEditingController(text: '${record?.port ?? 25565}');
    _target = TextEditingController(text: record?.target ?? '');
    _caaFlags = TextEditingController(text: '${record?.caaFlags ?? 0}');
    _caaValue = TextEditingController(text: record?.caaValue ?? '');
    _comment = TextEditingController(text: record?.comment ?? '');
    _tags = TextEditingController(text: record?.tags.join(', ') ?? '');
    _caaTag = record?.caaTag ?? caaPropertyTags.first;
    _proxied = record?.proxied ?? false;
    _ttlCustom = !_presetTtls.contains(record?.ttl ?? 1);
  }

  @override
  void dispose() {
    for (final controller in <TextEditingController>[
      _name,
      _content,
      _ttl,
      _priority,
      _weight,
      _port,
      _target,
      _caaFlags,
      _caaValue,
      _comment,
      _tags,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  DnsRecord _buildRecord() {
    final ttl = int.tryParse(_ttl.text) ?? 1;
    final initial = widget.initialRecord;
    final name = _name.text.trim();
    final commentText = _comment.text.trim();
    // An emptied comment is sent as '' so PATCH-based proxies clear it too.
    final comment = commentText.isEmpty && initial?.comment == null
        ? null
        : commentText;
    final tags = _tags.text
        .split(',')
        .map((tag) => tag.trim())
        .where((tag) => tag.isNotEmpty)
        .toList(growable: false);
    switch (_type) {
      case DnsRecordType.srv:
        return DnsRecord.srv(
          id: initial?.id,
          name: name,
          priority: int.tryParse(_priority.text) ?? -1,
          weight: int.tryParse(_weight.text) ?? -1,
          port: int.tryParse(_port.text) ?? -1,
          target: _target.text.trim(),
          ttl: ttl,
          comment: comment,
          tags: tags,
        );
      case DnsRecordType.mx:
        return DnsRecord.mx(
          id: initial?.id,
          name: name,
          priority: int.tryParse(_priority.text) ?? -1,
          mailServer: _content.text.trim(),
          ttl: ttl,
          comment: comment,
          tags: tags,
        );
      case DnsRecordType.caa:
        return DnsRecord.caa(
          id: initial?.id,
          name: name,
          flags: int.tryParse(_caaFlags.text) ?? -1,
          tag: _caaTag,
          value: _caaValue.text.trim(),
          ttl: ttl,
          comment: comment,
          tags: tags,
        );
      case DnsRecordType.a ||
          DnsRecordType.aaaa ||
          DnsRecordType.cname ||
          DnsRecordType.txt ||
          DnsRecordType.ns:
        return DnsRecord(
          id: initial?.id,
          type: _type,
          name: name,
          content: _content.text.trim(),
          ttl: ttl,
          proxied: _supportsProxy ? _proxied : false,
          comment: comment,
          tags: tags,
        );
    }
  }

  bool get _supportsProxy =>
      _type == DnsRecordType.a ||
      _type == DnsRecordType.aaaa ||
      _type == DnsRecordType.cname;

  String get _contentHint => switch (_type) {
    DnsRecordType.a => '192.0.2.1',
    DnsRecordType.aaaa => '2001:db8::1',
    DnsRecordType.cname => 'target.${widget.zoneName}',
    DnsRecordType.txt => 'Verification or policy value',
    DnsRecordType.mx => 'mail.${widget.zoneName}',
    DnsRecordType.ns => 'ns1.${widget.zoneName}',
    DnsRecordType.srv || DnsRecordType.caa => '',
  };

  String get _previewValue => switch (_type) {
    DnsRecordType.srv =>
      '${_priority.text} ${_weight.text} ${_port.text} '
          '${_textOr(_target, 'mc.${widget.zoneName}')}',
    DnsRecordType.mx => '${_priority.text} ${_textOr(_content, _contentHint)}',
    DnsRecordType.caa =>
      '${_caaFlags.text} $_caaTag "${_textOr(_caaValue, 'letsencrypt.org')}"',
    DnsRecordType.a ||
    DnsRecordType.aaaa ||
    DnsRecordType.cname ||
    DnsRecordType.txt ||
    DnsRecordType.ns => _textOr(_content, _contentHint),
  };

  String _textOr(TextEditingController controller, String fallback) =>
      controller.text.trim().isEmpty ? fallback : controller.text.trim();

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final record = _buildRecord();
    final issues = DnsRecordValidator.validate(record);
    if (issues.isNotEmpty) {
      setState(() => _formError = issues.first.message);
      return;
    }
    Navigator.of(context).pop(record);
  }

  void _selectType(DnsRecordType type) {
    if (type == _type) return;
    setState(() {
      _type = type;
      _formError = null;
    });
  }

  void _selectTtl(int? ttl) {
    setState(() {
      _ttlCustom = ttl == null;
      _ttl.text =
          ttl?.toString() ??
          (_presetTtls.contains(int.tryParse(_ttl.text)) ? '600' : _ttl.text);
      _formError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final motion = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 420);
    final quickMotion = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 220);
    final colors = Theme.of(context).colorScheme;
    final previewListenable = Listenable.merge(<Listenable>[
      _name,
      _content,
      _ttl,
      _priority,
      _weight,
      _port,
      _target,
      _caaFlags,
      _caaValue,
    ]);

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(24, 4, 24, 24 + bottom),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _EditorHeader(
              title: widget.initialRecord?.id == null
                  ? 'New DNS record'
                  : 'Edit DNS record',
              zoneName: widget.zoneName,
              type: _type,
              motion: motion,
            ),
            const SizedBox(height: 24),
            _sectionTitle(context, 'Record type'),
            const SizedBox(height: 10),
            _ExpressiveChoiceBar<DnsRecordType>(
              key: const ValueKey<String>('record-type-selector'),
              options: DnsRecordType.values
                  .map(
                    (type) => _ChoiceOption<DnsRecordType>(
                      value: type,
                      label: type.wireName,
                      icon: _typeIcon(type),
                    ),
                  )
                  .toList(growable: false),
              selected: _type,
              compactUnselected: true,
              selectedFactor: 2.15,
              motion: motion,
              semanticsSuffix: 'record type',
              onSelected: widget.initialRecord?.id == null ? _selectType : null,
            ),
            const SizedBox(height: 22),
            _sectionTitle(context, 'Name'),
            const SizedBox(height: 8),
            TextFormField(
              controller: _name,
              decoration: InputDecoration(
                hintText: widget.zoneName,
                helperText:
                    'Use @ for the root or a full name such as mc.${widget.zoneName}',
              ),
              validator: _required,
            ),
            const SizedBox(height: 18),
            AnimatedSize(
              duration: motion,
              curve: const Cubic(0.2, 0, 0, 1),
              alignment: Alignment.topCenter,
              child: AnimatedSwitcher(
                duration: motion,
                switchInCurve: const Cubic(0.2, 0, 0, 1),
                switchOutCurve: const Cubic(0.4, 0, 1, 1),
                layoutBuilder: (currentChild, previousChildren) => Stack(
                  alignment: Alignment.topCenter,
                  children: <Widget>[...previousChildren, ?currentChild],
                ),
                transitionBuilder: (child, animation) {
                  final curved = CurvedAnimation(
                    parent: animation,
                    curve: const Interval(0.38, 1, curve: Curves.easeOutCubic),
                    reverseCurve: const Interval(
                      0.65,
                      1,
                      curve: Curves.easeInCubic,
                    ),
                  );
                  return FadeTransition(
                    opacity: curved,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0.08, 0.03),
                        end: Offset.zero,
                      ).animate(curved),
                      child: ScaleTransition(
                        scale: Tween<double>(
                          begin: 0.96,
                          end: 1,
                        ).animate(curved),
                        child: child,
                      ),
                    ),
                  );
                },
                child: KeyedSubtree(
                  key: ValueKey<DnsRecordType>(_type),
                  child: _buildTypeFields(context, motion),
                ),
              ),
            ),
            const SizedBox(height: 20),
            _sectionTitle(context, 'Time to live'),
            const SizedBox(height: 9),
            _ExpressiveChoiceBar<int?>(
              key: const ValueKey<String>('ttl-selector'),
              options: const <_ChoiceOption<int?>>[
                _ChoiceOption<int?>(
                  value: 1,
                  label: 'Auto',
                  icon: Icons.auto_awesome_rounded,
                ),
                _ChoiceOption<int?>(
                  value: 300,
                  label: '5 min',
                  icon: Icons.bolt_rounded,
                ),
                _ChoiceOption<int?>(
                  value: 3600,
                  label: '1 hour',
                  icon: Icons.schedule_rounded,
                ),
                _ChoiceOption<int?>(
                  value: null,
                  label: 'Custom',
                  icon: Icons.tune_rounded,
                ),
              ],
              selected: _ttlCustom ? null : int.tryParse(_ttl.text),
              compactUnselected: false,
              selectedFactor: 1.28,
              motion: motion,
              semanticsSuffix: 'TTL',
              onSelected: _selectTtl,
            ),
            AnimatedSize(
              duration: motion,
              curve: const Cubic(0.2, 0, 0, 1),
              child: AnimatedSwitcher(
                duration: quickMotion,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SizeTransition(
                    sizeFactor: animation,
                    alignment: Alignment.topCenter,
                    child: child,
                  ),
                ),
                child: _ttlCustom
                    ? Padding(
                        key: const ValueKey<String>('custom-ttl-field'),
                        padding: const EdgeInsets.only(top: 12),
                        child: TextFormField(
                          controller: _ttl,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(
                            hintText: '600',
                            suffixText: 'seconds',
                          ),
                          validator: _numberValidator,
                        ),
                      )
                    : const SizedBox.shrink(
                        key: ValueKey<String>('preset-ttl-field'),
                      ),
              ),
            ),
            AnimatedSize(
              duration: motion,
              curve: const Cubic(0.2, 0, 0, 1),
              child: AnimatedSwitcher(
                duration: quickMotion,
                child: _supportsProxy
                    ? Padding(
                        key: const ValueKey<String>('proxy-setting'),
                        padding: const EdgeInsets.only(top: 16),
                        child: AnimatedContainer(
                          duration: motion,
                          curve: const Cubic(0.2, 0, 0, 1),
                          decoration: BoxDecoration(
                            color: _proxied
                                ? colors.primaryContainer
                                : colors.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(
                              _proxied ? 28 : 18,
                            ),
                          ),
                          child: Material(
                            color: Colors.transparent,
                            borderRadius: BorderRadius.circular(
                              _proxied ? 28 : 18,
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: SwitchListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              secondary: AnimatedSwitcher(
                                duration: quickMotion,
                                transitionBuilder: (child, animation) =>
                                    RotationTransition(
                                      turns: Tween<double>(
                                        begin: -0.12,
                                        end: 0,
                                      ).animate(animation),
                                      child: ScaleTransition(
                                        scale: animation,
                                        child: child,
                                      ),
                                    ),
                                child: Icon(
                                  _proxied
                                      ? Icons.cloud_done_rounded
                                      : Icons.cloud_outlined,
                                  key: ValueKey<bool>(_proxied),
                                ),
                              ),
                              title: const Text('Cloudflare proxy'),
                              subtitle: Text(
                                _proxied
                                    ? 'Traffic is protected and accelerated.'
                                    : 'DNS only — best for non-HTTP services.',
                              ),
                              value: _proxied,
                              onChanged: (value) {
                                setState(() => _proxied = value);
                              },
                            ),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(
                        key: ValueKey<String>('no-proxy-setting'),
                      ),
              ),
            ),
            const SizedBox(height: 20),
            _sectionTitle(context, 'Comment'),
            const SizedBox(height: 8),
            TextFormField(
              controller: _comment,
              decoration: const InputDecoration(
                hintText: 'Optional note for your team',
              ),
            ),
            const SizedBox(height: 18),
            _sectionTitle(context, 'Tags'),
            const SizedBox(height: 8),
            TextFormField(
              controller: _tags,
              decoration: const InputDecoration(
                hintText: 'env:prod, owner:web',
                helperText: 'Comma-separated name:value. Pro plan and above.',
              ),
            ),
            const SizedBox(height: 22),
            AnimatedBuilder(
              animation: previewListenable,
              builder: (context, _) => _RecordPreview(
                type: _type,
                name: _name.text.trim().isEmpty ? '@' : _name.text.trim(),
                value: _previewValue,
                ttl: _ttl.text,
                proxied: _supportsProxy && _proxied,
                motion: motion,
              ),
            ),
            if (_formError != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_formError!, style: TextStyle(color: colors.error)),
              ),
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
                    onPressed: _submit,
                    icon: const Icon(Icons.check_rounded),
                    label: const Text('Save record'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTypeFields(
    BuildContext context,
    Duration motion,
  ) => switch (_type) {
    DnsRecordType.srv => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: _numberField(context, _priority, 'Priority', hint: '0'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _numberField(context, _weight, 'Weight', hint: '0'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _numberField(context, _port, 'Port', hint: '25565'),
        const SizedBox(height: 18),
        _sectionTitle(context, 'Target hostname'),
        const SizedBox(height: 8),
        TextFormField(
          controller: _target,
          decoration: InputDecoration(hintText: 'mc.${widget.zoneName}'),
          validator: _required,
        ),
      ],
    ),
    DnsRecordType.mx => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _numberField(context, _priority, 'Priority', hint: '10'),
        const SizedBox(height: 18),
        _contentField(context, 'Mail server'),
      ],
    ),
    DnsRecordType.caa => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _numberField(context, _caaFlags, 'Flags', hint: '0'),
        const SizedBox(height: 18),
        _sectionTitle(context, 'Property'),
        const SizedBox(height: 10),
        _ExpressiveChoiceBar<String>(
          key: const ValueKey<String>('caa-tag-selector'),
          options: const <_ChoiceOption<String>>[
            _ChoiceOption<String>(
              value: 'issue',
              label: 'issue',
              icon: Icons.verified_user_outlined,
            ),
            _ChoiceOption<String>(
              value: 'issuewild',
              label: 'issuewild',
              icon: Icons.auto_awesome_mosaic_outlined,
            ),
            _ChoiceOption<String>(
              value: 'iodef',
              label: 'iodef',
              icon: Icons.report_outlined,
            ),
          ],
          selected: _caaTag,
          compactUnselected: false,
          selectedFactor: 1.28,
          motion: motion,
          semanticsSuffix: 'CAA property',
          onSelected: (tag) => setState(() {
            _caaTag = tag;
            _formError = null;
          }),
        ),
        const SizedBox(height: 18),
        _sectionTitle(context, 'Value'),
        const SizedBox(height: 8),
        TextFormField(
          controller: _caaValue,
          decoration: InputDecoration(
            hintText: _caaTag == 'iodef'
                ? 'mailto:security@${widget.zoneName}'
                : 'letsencrypt.org',
          ),
          validator: _required,
        ),
      ],
    ),
    DnsRecordType.txt => _contentField(context, 'TXT content', multiline: true),
    DnsRecordType.ns => _contentField(context, 'Nameserver'),
    DnsRecordType.a ||
    DnsRecordType.aaaa ||
    DnsRecordType.cname => _contentField(context, 'Content'),
  };

  Widget _contentField(
    BuildContext context,
    String label, {
    bool multiline = false,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      _sectionTitle(context, label),
      const SizedBox(height: 8),
      TextFormField(
        controller: _content,
        decoration: InputDecoration(hintText: _contentHint),
        minLines: multiline ? 2 : 1,
        maxLines: multiline ? 4 : 1,
        validator: _required,
      ),
    ],
  );

  Widget _numberField(
    BuildContext context,
    TextEditingController controller,
    String label, {
    required String hint,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      _sectionTitle(context, label),
      const SizedBox(height: 8),
      TextFormField(
        controller: controller,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(hintText: hint),
        validator: _numberValidator,
      ),
    ],
  );

  Widget _sectionTitle(BuildContext context, String label) => Text(
    label,
    style: Theme.of(
      context,
    ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
  );

  IconData _typeIcon(DnsRecordType type) => switch (type) {
    DnsRecordType.a => Icons.looks_one_outlined,
    DnsRecordType.aaaa => Icons.format_list_numbered_rounded,
    DnsRecordType.cname => Icons.redo_rounded,
    DnsRecordType.txt => Icons.notes_rounded,
    DnsRecordType.srv => Icons.hub_outlined,
    DnsRecordType.mx => Icons.mail_outline_rounded,
    DnsRecordType.caa => Icons.verified_user_outlined,
    DnsRecordType.ns => Icons.dns_outlined,
  };

  String? _numberValidator(String? value) {
    if (int.tryParse(value ?? '') == null) return 'Enter a number.';
    return null;
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? 'Required.' : null;
}

class _ChoiceOption<T> {
  const _ChoiceOption({
    required this.value,
    required this.label,
    required this.icon,
  });

  final T value;
  final String label;
  final IconData icon;
}

class _ExpressiveChoiceBar<T> extends StatelessWidget {
  const _ExpressiveChoiceBar({
    super.key,
    required this.options,
    required this.selected,
    required this.compactUnselected,
    required this.selectedFactor,
    required this.motion,
    required this.semanticsSuffix,
    this.onSelected,
  });

  final List<_ChoiceOption<T>> options;
  final T selected;
  final bool compactUnselected;
  final double selectedFactor;
  final Duration motion;
  final String semanticsSuffix;
  final ValueChanged<T>? onSelected;

  @override
  Widget build(BuildContext context) {
    const spacing = 6.0;
    // Below this width an unselected icon button no longer fits; scroll
    // horizontally instead of squeezing.
    const minBaseWidth = 44.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth - spacing * (options.length - 1);
        final fittedWidth = available / (options.length - 1 + selectedFactor);
        final scrolls = fittedWidth < minBaseWidth;
        final baseWidth = scrolls ? minBaseWidth : fittedWidth;
        final extraWidth = baseWidth * (selectedFactor - 1);
        final row = Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (var index = 0; index < options.length; index++) ...<Widget>[
              TweenAnimationBuilder<double>(
                key: ValueKey<T>(options[index].value),
                duration: motion,
                curve: const Cubic(0.2, 0, 0, 1),
                tween: Tween<double>(
                  end: options[index].value == selected ? 1 : 0,
                ),
                builder: (context, selectedAmount, _) => SizedBox(
                  width: baseWidth + extraWidth * selectedAmount,
                  height: 56,
                  child: _MorphingChoiceButton<T>(
                    option: options[index],
                    selectedAmount: selectedAmount,
                    compactUnselected: compactUnselected,
                    motion: motion,
                    semanticsSuffix: semanticsSuffix,
                    enabled: onSelected != null,
                    onTap: () {
                      onSelected?.call(options[index].value);
                      if (scrolls) {
                        Scrollable.ensureVisible(
                          context,
                          alignment: 0.5,
                          duration: motion,
                          curve: const Cubic(0.2, 0, 0, 1),
                        );
                      }
                    },
                  ),
                ),
              ),
              if (index != options.length - 1) const SizedBox(width: spacing),
            ],
          ],
        );
        if (!scrolls) return row;
        // Flutter ignores mouse drags on scrollables by default; allow them so
        // desktop and web users can reach every option.
        return ScrollConfiguration(
          behavior: ScrollConfiguration.of(
            context,
          ).copyWith(dragDevices: PointerDeviceKind.values.toSet()),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: row,
          ),
        );
      },
    );
  }
}

class _MorphingChoiceButton<T> extends StatefulWidget {
  const _MorphingChoiceButton({
    required this.option,
    required this.selectedAmount,
    required this.compactUnselected,
    required this.motion,
    required this.semanticsSuffix,
    required this.enabled,
    required this.onTap,
  });

  final _ChoiceOption<T> option;
  final double selectedAmount;
  final bool compactUnselected;
  final Duration motion;
  final String semanticsSuffix;
  final bool enabled;
  final VoidCallback onTap;

  @override
  State<_MorphingChoiceButton<T>> createState() =>
      _MorphingChoiceButtonState<T>();
}

class _MorphingChoiceButtonState<T> extends State<_MorphingChoiceButton<T>> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final amount = widget.selectedAmount.clamp(0.0, 1.0);
    final containerColor = Color.lerp(
      colors.surfaceContainerHighest,
      colors.primaryContainer,
      amount,
    );
    final foregroundColor = Color.lerp(
      colors.onSurfaceVariant,
      colors.onPrimaryContainer,
      amount,
    );
    final selectedShape = BorderRadius.only(
      topLeft: const Radius.circular(28),
      topRight: const Radius.circular(28),
      bottomLeft: const Radius.circular(28),
      bottomRight: Radius.circular(8 + 20 * (1 - amount)),
    );

    return Semantics(
      container: true,
      button: true,
      selected: amount > 0.5,
      label: '${widget.option.label} ${widget.semanticsSuffix}',
      child: ExcludeSemantics(
        child: AnimatedScale(
          scale: _pressed ? 0.96 : 1,
          duration: _pressed ? const Duration(milliseconds: 90) : widget.motion,
          curve: _pressed ? Curves.easeOut : Curves.easeOutBack,
          child: Material(
            color: containerColor,
            borderRadius: selectedShape,
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: widget.enabled ? widget.onTap : null,
              onHighlightChanged: (pressed) {
                if (mounted) setState(() => _pressed = pressed);
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Transform.scale(
                      scale: 1 + 0.06 * amount,
                      child: Icon(
                        widget.option.icon,
                        size: 19,
                        color: foregroundColor,
                      ),
                    ),
                    if (widget.compactUnselected) ...<Widget>[
                      SizedBox(width: 8 * amount),
                      Flexible(
                        child: ClipRect(
                          child: Align(
                            widthFactor: amount,
                            alignment: Alignment.centerLeft,
                            child: Opacity(
                              opacity: amount,
                              child: Text(
                                widget.option.label,
                                maxLines: 1,
                                overflow: TextOverflow.fade,
                                softWrap: false,
                                style: TextStyle(
                                  color: foregroundColor,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ] else ...<Widget>[
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          widget.option.label,
                          maxLines: 1,
                          overflow: TextOverflow.fade,
                          softWrap: false,
                          style: TextStyle(
                            color: foregroundColor,
                            fontWeight: FontWeight.lerp(
                              FontWeight.w600,
                              FontWeight.w800,
                              amount,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RecordPreview extends StatelessWidget {
  const _RecordPreview({
    required this.type,
    required this.name,
    required this.value,
    required this.ttl,
    required this.proxied,
    required this.motion,
  });

  final DnsRecordType type;
  final String name;
  final String value;
  final String ttl;
  final bool proxied;
  final Duration motion;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: motion,
      curve: const Cubic(0.2, 0, 0, 1),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: colors.tertiaryContainer,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(26),
          topRight: Radius.circular(26),
          bottomLeft: Radius.circular(26),
          bottomRight: Radius.circular(8),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.visibility_outlined,
                color: colors.onTertiaryContainer,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                'Live preview',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: colors.onTertiaryContainer,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const Spacer(),
              AnimatedSwitcher(
                duration: motion,
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: Tween<double>(
                      begin: 0.92,
                      end: 1,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: Container(
                  key: ValueKey<DnsRecordType>(type),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 9,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: colors.onTertiaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    type.wireName,
                    style: TextStyle(
                      color: colors.tertiaryContainer,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            name,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: colors.onTertiaryContainer,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: colors.onTertiaryContainer.withValues(alpha: 0.82),
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              _PreviewTag(
                icon: Icons.schedule_rounded,
                label: ttl == '1' ? 'Auto TTL' : '${ttl}s TTL',
              ),
              _PreviewTag(
                icon: proxied ? Icons.cloud_rounded : Icons.language_rounded,
                label: proxied ? 'Proxied' : 'DNS only',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PreviewTag extends StatelessWidget {
  const _PreviewTag({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: colors.onTertiaryContainer.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 14, color: colors.onTertiaryContainer),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: colors.onTertiaryContainer,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _EditorHeader extends StatelessWidget {
  const _EditorHeader({
    required this.title,
    required this.zoneName,
    required this.type,
    required this.motion,
  });

  final String title;
  final String zoneName;
  final DnsRecordType type;
  final Duration motion;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        AnimatedContainer(
          duration: motion,
          curve: const Cubic(0.2, 0, 0, 1),
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: colors.primaryContainer,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(20),
              topRight: Radius.circular(20),
              bottomLeft: Radius.circular(20),
              bottomRight: Radius.circular(7),
            ),
          ),
          child: AnimatedSwitcher(
            duration: motion,
            switchInCurve: const Interval(0.2, 1, curve: Curves.easeOutCubic),
            switchOutCurve: Curves.easeInCubic,
            layoutBuilder: (currentChild, previousChildren) => Stack(
              alignment: Alignment.center,
              children: <Widget>[...previousChildren, ?currentChild],
            ),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.88, end: 1).animate(animation),
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.12),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
            ),
            child: Icon(
              _headerIcon(type),
              key: ValueKey<String>('editor-type-mark-${type.wireName}'),
              color: colors.onPrimaryContainer,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              AnimatedSwitcher(
                duration: motion,
                switchInCurve: const Interval(
                  0.18,
                  1,
                  curve: Curves.easeOutCubic,
                ),
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.16),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: Text(
                  '$zoneName · ${type.wireName}',
                  key: ValueKey<DnsRecordType>(type),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Close',
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    );
  }

  IconData _headerIcon(DnsRecordType type) => switch (type) {
    DnsRecordType.a => Icons.language_rounded,
    DnsRecordType.aaaa => Icons.public_rounded,
    DnsRecordType.cname => Icons.alt_route_rounded,
    DnsRecordType.txt => Icons.verified_outlined,
    DnsRecordType.srv => Icons.sports_esports_rounded,
    DnsRecordType.mx => Icons.forward_to_inbox_rounded,
    DnsRecordType.caa => Icons.shield_outlined,
    DnsRecordType.ns => Icons.dns_rounded,
  };
}
