<p align="center">
  <img src="https://raw.githubusercontent.com/Seungpyo1007/flutter_cloudflare_dns/main/assets/flutter_cloudflare_dns-hero.png" alt="flutter_cloudflare_dns — Cloudflare DNS toolkit for Flutter" width="100%">
</p>

# flutter_cloudflare_dns

A Flutter-first toolkit for diagnosing and managing Cloudflare DNS. It ships
with a Material 3 dashboard, a public DNS-over-HTTPS health checker, and safe
gateway abstractions for A, AAAA, CNAME, TXT, SRV, MX, CAA, NS, HTTPS, SVCB,
and PTR records.

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
- Search records by name or value, copy values, and duplicate records.
- Compare Cloudflare and Google public DNS answers to check propagation, and
  watch a saved record until every resolver returns it.
- Export and import BIND zone files, compatible with Cloudflare's own DNS
  export.
- Apply many changes in one atomic Cloudflare batch request.
- Edit HTTPS and SVCB service bindings (priority, target, parameters) and PTR
  records.
- Retry rate-limited (HTTP 429) Cloudflare API requests automatically, and
  time out requests that hang.
- Validate records against Cloudflare's limits before sending them: TTL
  ranges per plan, automatic TTL for proxied records, record sizes, service
  binding parameters, and zone-wide rules such as a CNAME sharing its name
  with other records.
- Enter internationalized names such as `한국.example.com`; they are sent in
  Punycode and shown in Unicode.
- Watch a deleted record disappear from public resolvers, and see whether
  answers are DNSSEC-validated.
- Right-to-left layouts, large text, and dark mode are supported and tested.

## Installation

```yaml
dependencies:
  flutter_cloudflare_dns: ^0.3.0
```

The package requires Dart 3.12 and Flutter 3.44 or newer.

Upgrading from 0.2.x: proxied records with a TTL other than automatic (`1`)
fail validation, and `DnsDiagnostics.lookup` returns only answers of the
queried type. See the [changelog](CHANGELOG.md) for the full list.

Upgrading from 0.1.x: `DnsRecordType` now includes `https`, `svcb`, and `ptr`,
so exhaustive `switch` statements over it need the new cases. Upgrading from
0.0.x: `mx`, `caa`, and `ns` were added in 0.1.0.

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
| `POST` | `/dns-records/batch?zoneId=...` | Apply a batch (optional, see below) |

Responses may be a JSON result directly or wrapped as `{ "result": ... }`.
List requests carry a 1-based `page` parameter. To paginate, answer with
`{ "result": [...], "result_info": { "total_pages": 3 } }` — the gateway keeps
requesting pages until it reaches `total_pages`. A bare list is treated as the
only page. Errors may use `{ "message": "...", "code": "..." }` or
Cloudflare's `errors` array.

## Batch changes

`DirectCloudflareGateway` and `ProxyCloudflareGateway` also implement
`BatchCapableGateway`, which applies deletes, updates, and creates in one
request. Cloudflare applies all of them or none:

```dart
if (gateway is BatchCapableGateway) {
  final result = await gateway.batch(
    zoneId,
    posts: newRecords,
    patches: changedRecords, // each needs an id
    deletes: <String>['record-id'],
  );
  print('${result.posts.length} records created');
}
```

The proxy's batch endpoint receives Cloudflare's body unchanged:
`{ "deletes": [{ "id": ... }], "patches": [{ "id": ..., ... }], "posts":
[...] }`, and should answer with `{ "result": { "deletes": [...], "patches":
[...], "posts": [...] } }`. Forward it to Cloudflare's
`POST /zones/{zone_id}/dns_records/batch`. Cloudflare allows 200 changes per
batch on Free plans and 3,500 on paid plans, and runs deletes, then patches,
then posts.

`BatchCapableGateway` is a separate interface, so your own
`CloudflareDnsGateway` implementations keep compiling. The dashboard imports
zone files in batches of `importBatchSize` (200) when the gateway supports
it, and creates records one by one otherwise. Each batch is atomic, but an
import split into several batches is not: if a later batch fails, the
earlier ones stay applied. Records that were not created are listed in a
results sheet with the reason.

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

## Validation and plan limits

Gateways validate every record before a write with `DnsRecordValidator`, and
throw a `DnsValidationException` listing stable issue codes. The limits come
from Cloudflare's documentation:

- TTL is automatic (`1`) or 60 to 86,400 seconds; Enterprise zones allow 30.
  Pass `recordPolicy: DnsRecordPolicy.enterprise` to a gateway, and
  `recordPolicy` to the dashboard, to allow it.
- Proxied records always use automatic TTL (`proxied_ttl`). The editor locks
  the TTL choice when the proxy is on.
- A record's wire format is at most 4,096 bytes (`txt_too_long` for long TXT
  values), and records with the same name and type hold at most 8,192
  characters together.
- HTTPS and SVCB parameters must be valid RFC 9460 `key=value` pairs
  (`invalid_svc_params`).
- `0 .` is a null MX (the domain accepts no mail, RFC 7505), and an SRV
  target of `.` means the service is not offered.

`DnsRecordValidator.validateZone(records, zoneName: ...)` checks rules across
records: a CNAME cannot share its name with other records
(`cname_conflict`), identical records are rejected (`duplicate_record`), a
null MX must be the only MX (`null_mx_conflict`), and an apex CNAME is noted
as flattened. `validateInZone` checks one new or edited record against the
existing ones; the editor and the import preview use it.

Internationalized names are accepted anywhere a host name is:
`DnsName.toAscii('한국.example.com')` gives `xn--3e0b707e.example.com`, and
`DnsName.toUnicode` turns it back for display. Records are sent and exported
in Punycode, and the record list shows the Unicode form with the Punycode
name as a label.

## Timeouts and cleanup

Every gateway request fails with a `CloudflareDnsException` whose `code` is
`timeout` after `requestTimeout` (10 seconds by default; pass it to either
gateway's constructor). A timed-out write may still have reached Cloudflare,
so reload the records before retrying it.

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
`_minecraft._tcp.example.com|SRV`. Only answers of the queried type are
listed; `DnsDiagnostics.resolve` also returns the CNAME chain the resolver
followed, whether the name exists, and whether the answer was
DNSSEC-validated (`AD`). `DnsHealthReport.dnssecValidated` is true when every
lookup was, and the health card shows it.

Answers are compared the way DNS reads them: host names ignore case and the
trailing dot, IPv6 addresses compare by value, and a TXT value split into
several quoted strings (as long DKIM keys are) matches the joined value. TXT
values keep their case.

A CNAME at the zone apex is reported as `cname_flattened` (info) instead of
being looked up: Cloudflare flattens it into the target's A and AAAA
records, so public DNS never shows the CNAME itself.

Each lookup times out after `requestTimeout` (10 seconds), and at most
`maxConcurrentLookups` (8) run at once, so checking a large zone does not
flood the public resolvers. Both are `DnsDiagnostics` constructor options.

To check whether a change has reached other public resolvers, compare
Cloudflare and Google answers. A resolver that answers NXDOMAIN is listed in
`nxdomainResolvers`, not `failedResolvers`:

```dart
final comparisons = await DnsDiagnostics().compareResolvers([expected]);
for (final comparison in comparisons) {
  final state = comparison.consistent ? 'consistent' : 'differs';
  print('${comparison.name} ${comparison.type.wireName}: $state');
}
```

### Watching a change propagate

After saving a record, poll the public resolvers until they all return it:

```dart
final changed = DnsRecord(
  type: DnsRecordType.a,
  name: 'www.example.com',
  content: '192.0.2.10',
);
await for (final comparison in DnsDiagnostics().watchPropagation(changed)) {
  print(comparison.matches(changed) ? 'propagated' : 'still propagating');
}
```

It polls every 15 seconds for up to 10 minutes by default (`interval`,
`timeout`). The stream closes when `timeout` passes even if a lookup is still
running. The dashboard does this for every record you save that is not
proxied or an apex CNAME, and shows "Propagating", "Propagated", or "Not
visible everywhere yet" on the record.

Pass `removal: true` to wait for a deleted record to disappear instead; the
stream closes once `DnsResolverComparison.lacks` the record. The dashboard
watches every DNS-only record you delete and lists it under "Deleted
records" until public resolvers drop it.

The dashboard's automatic health check looks up at most
`maxHealthCheckRecords` (100) DNS-only records, apex records first, and adds
a `check_limited` info issue when a zone has more. "Compare resolvers" still
checks every record. Its record list is a sliver, so only visible records are
built; use `DnsRecordList.sliver` in your own `CustomScrollView` for the
same.

## Zone files

`DnsZoneFile` reads and writes BIND zone files. The output matches
Cloudflare's DNS export, so files move between this package and the
Cloudflare dashboard both ways. Record comments and tags travel in a
trailing comment, as Cloudflare writes them, with the reserved
`cf-proxied:true|false` tag:

```
www.example.com.	1	IN	A	192.0.2.1 ; web server cf_tags=team:web,cf-proxied:true
```

```dart
final text = DnsZoneFile.encode(records, origin: 'example.com');

final result = DnsZoneFile.parse(text, origin: 'example.com');
for (final issue in result.issues) {
  print('line ${issue.line}: ${issue.message}'); // e.g. SOA is skipped
}
```

`parse` handles `$ORIGIN`, `$TTL` (including units such as `1h`), `@`, blank
owner names, parentheses, comments, and multi-string TXT values. Records of
unsupported types are reported and skipped. Records without a TTL get the
`$TTL` value, or Cloudflare's automatic TTL (`1`); proxied records always get
automatic TTL. Other reserved `cf-` tags, such as `cf-flatten-cname`, are
dropped.

In the dashboard, the zone file menu next to refresh copies the zone as a zone
file, or imports a pasted one. The import preview validates every record,
skips records that already exist, and flags records that conflict with the
zone, such as a CNAME next to an existing A record.

## HTTPS, SVCB, and PTR records

```dart
final https = DnsRecord.https(
  name: 'example.com',
  priority: 1, // 0 makes an alias to `target` and takes no parameters
  params: 'alpn="h3,h2"',
); // target defaults to `.`, the record's own name

const reverse = DnsRecord(
  type: DnsRecordType.ptr,
  name: '1.2.0.192.in-addr.arpa',
  content: 'host.example.com',
);
```

Cloudflare accepts PTR records only in reverse DNS zones such as
`2.0.192.in-addr.arpa`.

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
accepted for TXT, CNAME, and SRV names, and a leading `*` label, as in
`*.example.com`, makes a wildcard record.

## Example

The `example/` app uses an in-memory gateway with web, Google verification TXT,
Minecraft SRV, MX, and CAA records, and simulated resolvers that pick up saved
and deleted records after a few polls. It is safe to run without a token on
any platform:

```sh
cd example
flutter run -d chrome   # or android, ios, windows, macos, linux
```

## Related packages

Pure Dart companions from the same publisher for checks beyond DNS records.
They run on every platform this package supports (`tls_inspector` excludes
the web):

| Package | What it checks |
| --- | --- |
| [rdap](https://pub.dev/packages/rdap) | Domain registration: expiry date, registrar, nameservers |
| [mail_dns_check](https://pub.dev/packages/mail_dns_check) | Email DNS: SPF, DMARC, DKIM, and MX |
| [tls_inspector](https://pub.dev/packages/tls_inspector) | TLS certificates: issuer, expiry, covered names, trust |

## Security and support

- Tokens are supplied per request and are never included in exception messages.
- Record writes are validated before network calls.
- Deletion in the dashboard requires confirmation.
- Record types other than A, AAAA, CNAME, TXT, SRV, MX, CAA, NS, HTTPS, SVCB,
  and PTR are skipped when listing records.

Issues and contributions are welcome on
[GitHub](https://github.com/Seungpyo1007/flutter_cloudflare_dns).
