/// A Cloudflare DNS zone.
class DnsZone {
  /// Creates a zone.
  const DnsZone({required this.id, required this.name, this.status});

  /// Parses a Cloudflare-compatible zone JSON object.
  factory DnsZone.fromJson(Map<String, Object?> json) => DnsZone(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    status: json['status']?.toString(),
  );

  /// Cloudflare zone ID.
  final String id;

  /// Zone hostname.
  final String name;

  /// Cloudflare zone status, such as `active`.
  final String? status;
}
