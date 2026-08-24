/// DNS record types supported by the package.
enum DnsRecordType {
  a('A'),
  aaaa('AAAA'),
  cname('CNAME'),
  txt('TXT'),
  srv('SRV');

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

/// An A, AAAA, CNAME, TXT, or SRV DNS record.
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
    this.priority,
    this.weight,
    this.port,
    this.target,
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
  }) {
    return DnsRecord(
      id: id,
      type: DnsRecordType.srv,
      name: name,
      content: '$priority $weight $port $target',
      ttl: ttl,
      proxied: false,
      comment: comment,
      priority: priority,
      weight: weight,
      port: port,
      target: target,
    );
  }

  /// Parses a Cloudflare-compatible record JSON object.
  factory DnsRecord.fromJson(Map<String, Object?> json) {
    final type = DnsRecordType.parse(json['type']);
    final data = _objectMap(json['data']);
    final rawContent = json['content']?.toString() ?? '';
    final srvParts = type == DnsRecordType.srv
        ? rawContent.trim().split(RegExp(r'\s+'))
        : const <String>[];

    int? srvValue(String key, int index) {
      return _asInt(data?[key]) ??
          _asInt(json[key]) ??
          (srvParts.length >= 4 ? _asInt(srvParts[index]) : null);
    }

    final priority = srvValue('priority', 0);
    final weight = srvValue('weight', 1);
    final port = srvValue('port', 2);
    final target =
        data?['target']?.toString() ??
        json['target']?.toString() ??
        (srvParts.length >= 4 ? srvParts.sublist(3).join(' ') : null);
    final content =
        type == DnsRecordType.srv &&
            priority != null &&
            weight != null &&
            port != null &&
            target != null
        ? '$priority $weight $port $target'
        : rawContent;

    return DnsRecord(
      id: json['id']?.toString(),
      type: type,
      name: json['name']?.toString() ?? '',
      content: content,
      ttl: _asInt(json['ttl']) ?? 1,
      proxied: json['proxied'] as bool?,
      comment: json['comment']?.toString(),
      priority: priority,
      weight: weight,
      port: port,
      target: target,
    );
  }

  /// Cloudflare's record identifier, if this record came from its API.
  final String? id;

  /// DNS record type.
  final DnsRecordType type;

  /// Fully qualified or zone-relative record name.
  final String name;

  /// Record content. SRV content is `priority weight port target`.
  final String content;

  /// TTL in seconds. Cloudflare uses `1` for automatic TTL.
  final int ttl;

  /// Whether Cloudflare proxies the record, when supported.
  final bool? proxied;

  /// Optional Cloudflare record comment.
  final String? comment;

  /// SRV priority.
  final int? priority;

  /// SRV weight.
  final int? weight;

  /// SRV target port.
  final int? port;

  /// SRV target hostname.
  final String? target;

  /// Serializes this record for the Cloudflare DNS API.
  Map<String, Object?> toCloudflareJson() {
    final json = <String, Object?>{
      'type': type.wireName,
      'name': name,
      'ttl': ttl,
      if (comment != null && comment!.isNotEmpty) 'comment': comment,
    };
    if (type == DnsRecordType.srv) {
      json['data'] = <String, Object?>{
        'priority': priority,
        'weight': weight,
        'port': port,
        'target': target,
      };
    } else {
      json['content'] = content;
      if (proxied != null &&
          (type == DnsRecordType.a ||
              type == DnsRecordType.aaaa ||
              type == DnsRecordType.cname)) {
        json['proxied'] = proxied;
      }
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
    int? priority,
    int? weight,
    int? port,
    String? target,
  }) {
    return DnsRecord(
      id: id ?? this.id,
      type: type ?? this.type,
      name: name ?? this.name,
      content: content ?? this.content,
      ttl: ttl ?? this.ttl,
      proxied: proxied ?? this.proxied,
      comment: comment ?? this.comment,
      priority: priority ?? this.priority,
      weight: weight ?? this.weight,
      port: port ?? this.port,
      target: target ?? this.target,
    );
  }

  /// Normalized content used by diagnostics.
  String get canonicalContent {
    final value = type == DnsRecordType.srv
        ? '${priority ?? 0} ${weight ?? 0} ${port ?? 0} ${target ?? ''}'
        : type == DnsRecordType.txt
        ? content.trim().replaceAll(RegExp(r'^"|"$'), '')
        : content;
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
