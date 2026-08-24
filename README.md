<p align="center">
  <img src="https://raw.githubusercontent.com/Seungpyo1007/flutter_cloudflare_dns/main/assets/flutter_cloudflare_dns-hero.png" alt="flutter_cloudflare_dns — Cloudflare DNS toolkit for Android" width="100%">
</p>

# flutter_cloudflare_dns

A Flutter-first toolkit for diagnosing and managing Cloudflare DNS. It ships
with a Material 3 dashboard, a public DNS-over-HTTPS health checker, and safe
gateway abstractions for A, AAAA, CNAME, TXT, and SRV records.

> **Platform support:** version 0.0.3 officially supports Android only. Other
> Flutter platforms are planned, but are not part of the current support policy.

## Android demo

<p align="center">
  <img src="https://raw.githubusercontent.com/Seungpyo1007/flutter_cloudflare_dns/main/assets/flutter_cloudflare_dns-demo.webp" alt="High-resolution Android demo showing the DNS dashboard and SRV record editor" width="480">
</p>

The demo shows the Material 3 dashboard, record filtering, the motion-driven
type picker, SRV fields, TTL presets, and live record preview. You can also
[watch the full-resolution Android demo](https://github.com/Seungpyo1007/flutter_cloudflare_dns/blob/main/media/flutter_cloudflare_dns-android-demo.mp4).

## Features

- Inspect public DNS through Cloudflare DNS-over-HTTPS on Android.
- Compare public answers with configured records and receive stable issue codes.
- List zones and create, update, or delete supported Cloudflare DNS records.
- Use a backend proxy by default so Cloudflare API tokens stay off user devices.
- Opt into direct Cloudflare API access for trusted personal/internal tools.
- Drop in an adaptive Material 3 dashboard with a large app bar, tonal health
  surfaces, record filters, a floating create action, and a mobile editor sheet.
- Edit SRV priority, weight, port, and target fields for Minecraft and other services.

## Installation

```yaml
dependencies:
  flutter_cloudflare_dns: ^0.0.3
```

The package requires Dart 3.12 and Flutter 3.44 or newer.

## Recommended: backend proxy

The proxy gateway calls your application backend. The Cloudflare token belongs
in that backend's secret store, never in the Flutter bundle.

```dart
final gateway = ProxyCloudflareGateway(
  baseUri: Uri.parse('https://api.example.com/cloudflare-dns'),
  headersProvider: () async => {
    'authorization': 'Bearer ${await appSession.accessToken()}',
  },
);

MaterialApp(
  theme: ThemeData(useMaterial3: true),
  home: Scaffold(
    body: CloudflareDnsDashboard(
      gateway: gateway,
      initialZoneName: 'example.com',
    ),
  ),
);
```

The proxy REST contract is:

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/zones` | List accessible zones |
| `GET` | `/dns-records?zoneId=...` | List records |
| `POST` | `/dns-records?zoneId=...` | Create a record |
| `PATCH` | `/dns-records/{id}?zoneId=...` | Update a record |
| `DELETE` | `/dns-records/{id}?zoneId=...` | Delete a record |

Responses may be a JSON result directly or wrapped as `{ "result": ... }`.
Errors may use `{ "message": "...", "code": "..." }` or Cloudflare's
`errors` array.

## Direct Cloudflare API access

Direct access is for personal or tightly controlled internal tools. A token in
a distributed mobile or web app can be extracted. The explicit risk flag makes
this choice visible in code, and the callback keeps the token out of package
state. The package never persists or logs it.

```dart
final gateway = DirectCloudflareGateway(
  acknowledgeTokenRisk: true,
  tokenProvider: () => secureRuntimeTokenPrompt(),
);
```

Create a scoped Cloudflare API token with only **Zone: Read** and
**DNS: Edit** for the zones the tool manages. Do not use the Global API Key.

## Public DNS diagnostics

Diagnostics do not require a Cloudflare account or token.

```dart
final expected = DnsRecord.srv(
  name: '_minecraft._tcp.example.com',
  priority: 0,
  weight: 0,
  port: 25565,
  target: 'mc.example.com',
);

final report = await DnsDiagnostics().check(
  'example.com',
  types: const [DnsRecordType.a, DnsRecordType.cname],
  expectedRecords: [expected],
);

for (final issue in report.issues) {
  print('${issue.code}: ${issue.message}');
}
```

`DnsHealthReport.answers` is keyed by `name|TYPE`, for example
`_minecraft._tcp.example.com|SRV`.

## Minecraft Java SRV record

To let players enter `example.com` while the server runs on
`mc.example.com:25566`, create:

```dart
final record = DnsRecord.srv(
  name: '_minecraft._tcp.example.com',
  priority: 0,
  weight: 0,
  port: 25566,
  target: 'mc.example.com',
);
```

The target must have an A or AAAA record. Keep Minecraft host records DNS-only;
Cloudflare's ordinary HTTP proxy does not proxy Minecraft TCP traffic.

## Example

The `example/` app uses an in-memory gateway with web, Google verification TXT,
and Minecraft SRV records. It is safe to run without a token:

```sh
cd example
flutter run
```

## Security and support

- Tokens are supplied per request and are never included in exception messages.
- Record writes are validated before network calls.
- Deletion in the dashboard requires confirmation.
- Unsupported DNS record types are intentionally excluded in v1.

Issues and contributions are welcome on
[GitHub](https://github.com/Seungpyo1007/flutter_cloudflare_dns).
