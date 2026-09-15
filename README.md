<p align="center">
  <img src="https://raw.githubusercontent.com/Seungpyo1007/flutter_cloudflare_dns/main/assets/flutter_cloudflare_dns-hero.png" alt="flutter_cloudflare_dns — Cloudflare DNS toolkit for Flutter" width="100%">
</p>

# flutter_cloudflare_dns

A Flutter-first toolkit for diagnosing and managing Cloudflare DNS. It ships
with a Material 3 dashboard, a public DNS-over-HTTPS health checker, and safe
gateway abstractions for A, AAAA, CNAME, TXT, SRV, MX, CAA, and NS records.

## Platform support

The package is pure Dart on top of `package:http`, so it runs on every Flutter
platform. The only difference is on the web, where browsers enforce CORS.

| Platform | Diagnostics | `ProxyCloudflareGateway` | `DirectCloudflareGateway` | Widgets |
| --- | --- | --- | --- | --- |
| Android, iOS | Yes | Yes | Yes | Yes |
| Windows, macOS, Linux | Yes | Yes | Yes | Yes |
| Web | Yes | Yes, if your backend allows CORS | No — the Cloudflare API sends no CORS headers | Yes |

Apps still need network access: the `INTERNET` permission on Android release
builds and the `com.apple.security.network.client` entitlement on macOS.

## Android demo

<p align="center">
  <img src="https://raw.githubusercontent.com/Seungpyo1007/flutter_cloudflare_dns/main/assets/flutter_cloudflare_dns-demo.webp" alt="Full-height two-phone Android demo showing live DNS health and SRV record editing" width="100%">
</p>

The demo shows the Material 3 dashboard, record filtering, the motion-driven
type picker, SRV fields, TTL presets, and live record preview. You can also
[watch the full-resolution Android demo](https://github.com/Seungpyo1007/flutter_cloudflare_dns/blob/main/media/flutter_cloudflare_dns-android-demo.mp4).

## Features

- Inspect public DNS through Cloudflare DNS-over-HTTPS.
- Compare public answers with configured records and receive stable issue codes.
- List every zone and record (paginated responses are followed automatically)
  and create, update, or delete supported Cloudflare DNS records.
- Use a backend proxy by default so Cloudflare API tokens stay off user devices.
- Opt into direct Cloudflare API access for trusted personal/internal tools.
- Drop in an adaptive Material 3 dashboard with a large app bar, tonal health
  surfaces, record filters, a floating create action, and a mobile editor sheet.
- Edit SRV priority, weight, port, and target fields for Minecraft and other
  services, MX mail routing, and CAA certificate authority policies.
- Edit Cloudflare record comments and tags (tags need a Pro plan or above).

## Installation

```yaml
dependencies:
  flutter_cloudflare_dns: ^0.1.1
```

The package requires Dart 3.12 and Flutter 3.44 or newer.

Upgrading from 0.0.x: `DnsRecordType` now includes `mx`, `caa`, and `ns`, so
exhaustive `switch` statements over it need the new cases.

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
| `GET` | `/zones?page=...` | List accessible zones |
| `GET` | `/dns-records?zoneId=...&page=...` | List records |
| `POST` | `/dns-records?zoneId=...` | Create a record |
| `PATCH` | `/dns-records/{id}?zoneId=...` | Update a record |
| `DELETE` | `/dns-records/{id}?zoneId=...` | Delete a record |

Responses may be a JSON result directly or wrapped as `{ "result": ... }`.
List requests carry a 1-based `page` parameter. To paginate, answer with
`{ "result": [...], "result_info": { "total_pages": 3 } }` — the gateway keeps
requesting pages until it reaches `total_pages`. A bare list is treated as the
only page. Errors may use `{ "message": "...", "code": "..." }` or
Cloudflare's `errors` array.

## Direct Cloudflare API access

Direct access is for personal or tightly controlled internal tools. A token in
a distributed mobile or desktop app can be extracted. The explicit risk flag
makes this choice visible in code, and the callback keeps the token out of
package state. The package never persists or logs it.

```dart
final gateway = DirectCloudflareGateway(
  acknowledgeTokenRisk: true,
  tokenProvider: () => secureRuntimeTokenPrompt(),
);
```

Create a scoped Cloudflare API token with only **Zone: Read** and
**DNS: Edit** for the zones the tool manages. Do not use the Global API Key.
Direct access does not work in Flutter web builds because the Cloudflare API
does not allow cross-origin browser requests.

Call `close()` on gateways and `DnsDiagnostics` instances you create when you
no longer need them. Clients you pass in stay open for you to close. The
dashboard closes only the diagnostics client it creates itself.

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

## Mail and certificate records

```dart
final mail = DnsRecord.mx(
  name: '@',
  priority: 10,
  mailServer: 'mail.example.com',
);

final letsEncryptOnly = DnsRecord.caa(
  name: 'example.com',
  tag: 'issue', // issue, issuewild, or iodef
  value: 'letsencrypt.org',
);
```

Use `@` for the zone apex. Underscore labels such as `_dmarc.example.com` are
accepted for TXT, CNAME, and SRV names.

## Example

The `example/` app uses an in-memory gateway with web, Google verification TXT,
Minecraft SRV, MX, and CAA records. It is safe to run without a token on any
platform:

```sh
cd example
flutter run -d chrome   # or android, ios, windows, macos, linux
```

## Security and support

- Tokens are supplied per request and are never included in exception messages.
- Record writes are validated before network calls.
- Deletion in the dashboard requires confirmation.
- Record types other than A, AAAA, CNAME, TXT, SRV, MX, CAA, and NS are skipped
  when listing records.

Issues and contributions are welcome on
[GitHub](https://github.com/Seungpyo1007/flutter_cloudflare_dns).
