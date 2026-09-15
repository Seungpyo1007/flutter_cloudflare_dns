/// DNS record types supported by the package.
enum DnsRecordType {
  a('A'),
  aaaa('AAAA'),
  cname('CNAME'),
  txt('TXT'),
  srv('SRV'),
  mx('MX'),
  caa('CAA'),
  ns('NS');

  const DnsRecordType(this.wireName);

  /// The uppercase value used by DNS and the Cloudflare API.
  final String wireName;

  /// Parses a DNS type returned by an API.
  static DnsRecordType parse(Object? value) {
    final normalized = value?.toString().toUpperCase();
    return values.firstWhere(
      (type) => type.wireName == normalized,
      orElse: () => throw FormatException('Unsupported DNS type: $value'),
    );
  }

  /// Parses a supported type, returning null for all other DNS types.
  static DnsRecordType? tryParse(Object? value) {
    final normalized = value?.toString().toUpperCase();
    for (final type in values) {
      if (type.wireName == normalized) return type;
    }
    return null;
  }
}

/// CAA property tags accepted by [DnsRecord.caa].
const List<String> caaPropertyTags = <String>['issue', 'issuewild', 'iodef'];

/// A supported DNS record: A, AAAA, CNAME, TXT, SRV, MX, CAA, or NS.
class DnsRecord {
  /// Creates a DNS record.
  const DnsRecord({
    this.id,
    required this.type,
    required this.name,
    required this.content,
    this.ttl = 1,
    this.proxied,
    this.comment,
    this.tags = const <String>[],
    this.priority,
    this.weight,
    this.port,
    this.target,
    this.caaFlags,
    this.caaTag,
    this.caaValue,
  });

  /// Creates an SRV record.
  factory DnsRecord.srv({
    String? id,
    required String name,
    required int priority,
    required int weight,
    required int port,
    required String target,
    int ttl = 1,
    String? comment,
    List<String> tags = const <String>[],
  }) {
    return DnsRecord(
      id: id,
      type: DnsRecordType.srv,
      name: name,
      content: '$priority $weight $port $target',
      ttl: ttl,
      proxied: false,
      comment: comment,
      tags: tags,
      priority: priority,
      weight: weight,
      port: port,
      target: target,
    );
  }

  /// Creates an MX record that routes mail for [name] to [mailServer].
  factory DnsRecord.mx({
    String? id,
    required String name,
    required int priority,
    required String mailServer,
    int ttl = 1,
    String? comment,
    List<String> tags = const <String>[],
  }) {
    return DnsRecord(
      id: id,
      type: DnsRecordType.mx,
      name: name,
      content: mailServer,
      ttl: ttl,
      proxied: false,
      comment: comment,
      tags: tags,
      priority: priority,
    );
  }

  /// Creates a CAA record, for example `0 issue "letsencrypt.org"`.
  ///
  /// [tag] should be one of [caaPropertyTags].
  factory DnsRecord.caa({
    String? id,
    required String name,
    int flags = 0,
    required String tag,
    required String value,
    int ttl = 1,
    String? comment,
    List<String> tags = const <String>[],
  }) {
    return DnsRecord(
      id: id,
      type: DnsRecordType.caa,
      name: name,
      content: '$flags $tag "$value"',
      ttl: ttl,
      proxied: false,
      comment: comment,
      tags: tags,
      caaFlags: flags,
      caaTag: tag,
      caaValue: value,
    );
  }

  /// Parses a Cloudflare-compatible or DNS-over-HTTPS record JSON object.
  factory DnsRecord.fromJson(Map<String, Object?> json) {
    final type = DnsRecordType.parse(json['type']);
    final data = _objectMap(json['data']);
    final rawContent = json['content']?.toString() ?? '';
    final rawTags = json['tags'];
    final tags = rawTags is List
        ? rawTags.map((tag) => tag.toString()).toList(growable: false)
        : const <String>[];

    var content = rawContent;
    int? priority;
    int? weight;
    int? port;
    String? target;
    int? caaFlags;
    String? caaTag;
    String? caaValue;

    switch (type) {
      case DnsRecordType.srv:
        final parts = rawContent.trim().split(RegExp(r'\s+'));
        int? srvValue(String key, int index) {
          return _asInt(data?[key]) ??
              _asInt(json[key]) ??
              (parts.length >= 4 ? _asInt(parts[index]) : null);
        }

        priority = srvValue('priority', 0);
        weight = srvValue('weight', 1);
        port = srvValue('port', 2);
        target =
            data?['target']?.toString() ??
            json['target']?.toString() ??
            (parts.length >= 4 ? parts.sublist(3).join(' ') : null);
        if (priority != null &&
            weight != null &&
            port != null &&
            target != null) {
          content = '$priority $weight $port $target';
        }
      case DnsRecordType.mx:
        // Cloudflare keeps the priority separate; DoH answers inline it as
        // `10 mail.example.com.`.
        priority = _asInt(json['priority']) ?? _asInt(data?['priority']);
        final inline = RegExp(r'^\s*(\d+)\s+(\S+)\s*$').firstMatch(rawContent);
        if (priority == null && inline != null) {
          priority = int.parse(inline.group(1)!);
          content = inline.group(2)!;
        }
      case DnsRecordType.caa:
        final inline = RegExp(
          r'^\s*(\d+)\s+(\S+)\s+(.*?)\s*$',
        ).firstMatch(rawContent);
        caaFlags = _asInt(data?['flags']) ?? _asInt(inline?.group(1));
        caaTag = data?['tag']?.toString() ?? inline?.group(2);
        caaValue =
            data?['value']?.toString() ??
            inline?.group(3)?.replaceAll(RegExp(r'^"|"$'), '');
        if (caaFlags != null && caaTag != null && caaValue != null) {
          content = '$caaFlags $caaTag "$caaValue"';
        }
      case DnsRecordType.a ||
          DnsRecordType.aaaa ||
          DnsRecordType.cname ||
          DnsRecordType.txt ||
          DnsRecordType.ns:
        break;
    }

    return DnsRecord(
      id: json['id']?.toString(),
      type: type,
      name: json['name']?.toString() ?? '',
      content: content,
      ttl: _asInt(json['ttl']) ?? 1,
      proxied: json['proxied'] as bool?,
      comment: json['comment']?.toString(),
      tags: tags,
      priority: priority,
      weight: weight,
      port: port,
      target: target,
      caaFlags: caaFlags,
      caaTag: caaTag,
      caaValue: caaValue,
    );
  }

  /// Cloudflare's record identifier, if this record came from its API.
  final String? id;

  /// DNS record type.
  final DnsRecordType type;

  /// Fully qualified or zone-relative record name.
  final String name;

  /// Record content. SRV content is `priority weight port target`, MX content
  /// is the mail server hostname, and CAA content is `flags tag "value"`.
  final String content;

  /// TTL in seconds. Cloudflare uses `1` for automatic TTL.
  final int ttl;

  /// Whether Cloudflare proxies the record, when supported.
  final bool? proxied;

  /// Optional Cloudflare record comment.
  final String? comment;

  /// Cloudflare record tags, each formatted as `name` or `name:value`.
  final List<String> tags;

  /// SRV or MX priority.
  final int? priority;

  /// SRV weight.
  final int? weight;

  /// SRV target port.
  final int? port;

  /// SRV target hostname.
  final String? target;

  /// CAA flags, usually `0`.
  final int? caaFlags;

  /// CAA property tag, one of [caaPropertyTags].
  final String? caaTag;

  /// CAA property value, such as `letsencrypt.org`.
  final String? caaValue;

  /// Serializes this record for the Cloudflare DNS API.
  Map<String, Object?> toCloudflareJson() {
    final json = <String, Object?>{
      'type': type.wireName,
      'name': name,
      'ttl': ttl,
      // An empty comment is sent on purpose: it clears the comment on PATCH.
      if (comment != null) 'comment': comment,
      if (tags.isNotEmpty) 'tags': tags,
    };
    switch (type) {
      case DnsRecordType.srv:
        json['data'] = <String, Object?>{
          'priority': priority,
          'weight': weight,
          'port': port,
          'target': target,
        };
      case DnsRecordType.caa:
        json['data'] = <String, Object?>{
          'flags': caaFlags,
          'tag': caaTag,
          'value': caaValue,
        };
      case DnsRecordType.mx:
        json['content'] = content;
        json['priority'] = priority;
      case DnsRecordType.a || DnsRecordType.aaaa || DnsRecordType.cname:
        json['content'] = content;
        if (proxied != null) json['proxied'] = proxied;
      case DnsRecordType.txt || DnsRecordType.ns:
        json['content'] = content;
    }
    return json;
  }

  /// Returns an updated copy.
  DnsRecord copyWith({
    String? id,
    DnsRecordType? type,
    String? name,
    String? content,
    int? ttl,
    bool? proxied,
    String? comment,
    List<String>? tags,
    int? priority,
    int? weight,
    int? port,
    String? target,
    int? caaFlags,
    String? caaTag,
    String? caaValue,
  }) {
    return DnsRecord(
      id: id ?? this.id,
      type: type ?? this.type,
      name: name ?? this.name,
      content: content ?? this.content,
      ttl: ttl ?? this.ttl,
      proxied: proxied ?? this.proxied,
      comment: comment ?? this.comment,
      tags: tags ?? this.tags,
      priority: priority ?? this.priority,
      weight: weight ?? this.weight,
      port: port ?? this.port,
      target: target ?? this.target,
      caaFlags: caaFlags ?? this.caaFlags,
      caaTag: caaTag ?? this.caaTag,
      caaValue: caaValue ?? this.caaValue,
    );
  }

  /// Normalized content used by diagnostics.
  String get canonicalContent {
    final value = switch (type) {
      DnsRecordType.srv =>
        '${priority ?? 0} ${weight ?? 0} ${port ?? 0} ${target ?? ''}',
      DnsRecordType.mx =>
        '${priority ?? 0} ${content.trim().replaceAll(RegExp(r'\.$'), '')}',
      DnsRecordType.caa => '${caaFlags ?? 0} ${caaTag ?? ''} ${caaValue ?? ''}',
      DnsRecordType.txt => content.trim().replaceAll(RegExp(r'^"|"$'), ''),
      DnsRecordType.a ||
      DnsRecordType.aaaa ||
      DnsRecordType.cname ||
      DnsRecordType.ns => content,
    };
    return value.trim().replaceAll(RegExp(r'\.$'), '').toLowerCase();
  }
}

Map<String, Object?>? _objectMap(Object? value) {
  if (value is! Map) return null;
  return value.map((key, item) => MapEntry(key.toString(), item));
}

int? _asInt(Object? value) {
  if (value is int) return value;
  return int.tryParse(value?.toString() ?? '');
}
