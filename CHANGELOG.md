## 0.1.2

* Search records by name or value from the dashboard.
* Compare public answers from Cloudflare and Google DNS-over-HTTPS resolvers
  with `DnsDiagnostics.compareResolvers` and the dashboard's
  "Compare resolvers" sheet to see whether a change has propagated.
* Copy a record value or duplicate a record from the record menu. The editor
  treats a record without an `id` as a new record.
* Retry Cloudflare API requests that return HTTP 429, honoring `Retry-After`.
* Replace the `minecraft` pub.dev topic with `material-design` and `ui`.

## 0.1.1

* Fix `CloudflareDnsDashboard` creating a new HTTP client for every health
  check without closing it. It now reuses one and closes it on dispose.
* Add `close()` to `DnsDiagnostics`, `DirectCloudflareGateway`, and
  `ProxyCloudflareGateway`. Only clients they created are closed.
* Edit record comments and tags in the editor sheet. Clearing a comment now
  sends an empty value so proxies using PATCH remove it.
* Validate Cloudflare limits: comments up to 500 characters, up to 20 tags,
  tag names of letters, digits, `-`, or `_` up to 32 characters, values up
  to 100 characters.
* Publish releases to pub.dev from GitHub Actions when a `v*` tag is pushed.

## 0.1.0

**Breaking:** `DnsRecordType` gains `mx`, `caa`, and `ns`. Exhaustive `switch`
statements over the enum need the new cases.

* Fix zone and record listing silently stopping after the first page. Both
  gateways now follow `result_info.total_pages`; proxies that return a bare
  list keep working.
* Add MX, CAA, and NS records to the model, validator, DoH diagnostics,
  record list, editor sheet, and dashboard filters.
* Add Cloudflare record `tags`, preserved when editing a record.
* Accept `@` for the zone apex and underscore labels such as `_dmarc` for TXT
  and CNAME names.
* Declare iOS, web, Windows, macOS, and Linux support. `DirectCloudflareGateway`
  cannot call the Cloudflare API from web browsers because of CORS; use the
  proxy gateway there.
* Keep the record type selector usable on narrow screens by scrolling instead
  of shrinking buttons.
* Document the remaining public REST gateway members and the library.
* Lower the Dart SDK constraint to `^3.12.0` so the documented Flutter 3.44.0
  minimum (which ships Dart 3.12.0) can actually resolve the package.
* Require `http` 1.6.0 and verify against Flutter 3.47.
* Add GitHub Actions CI for formatting, analysis, tests, pana, and example builds.

## 0.0.5

* Expand the two-panel demo to 1920x2160 so both Android screens remain full height.
* Keep the complete status bar, editor form, live preview, and save controls visible.
* Publish a matching 960x1080 animated WebP for GitHub and pub.dev.

## 0.0.4

* Rebuild the demo as a space-efficient two-panel 1920x1080 Android presentation.
* Preserve real dashboard, editor, scrolling, and health-check animations.
* Upgrade the pub.dev animation to 960x540 at 12 fps while staying below the image limit.
* Correct label and chip text alignment throughout the package artwork.

## 0.0.3

* Replace the package hero and screenshot gallery with polished high-resolution artwork.
* Upgrade the Android demo to a crisp 1080x2340, 30 fps presentation.
* Use absolute GitHub media URLs so README visuals render reliably on pub.dev.

## 0.0.2

* Add branded package artwork and an animated Android demo.
* Link the public GitHub repository and issue tracker.
* Refresh the package screenshots with real Android UI.

## 0.0.1

* Add Cloudflare DoH diagnostics for A, AAAA, CNAME, TXT, and SRV records.
* Add direct and backend-proxy Cloudflare DNS gateways.
* Add a Material 3 DNS dashboard, health card, record list, and editor.
* Add safe SRV editing for services such as Minecraft Java Edition.
* Declare Android as the officially supported platform for the initial release.
