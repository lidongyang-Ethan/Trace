# Trace

**English** | [简体中文](README.zh-CN.md)

An iOS network diagnostics panel built on Alamofire's `EventMonitor`. A **0.1.1 development preview** distributed through Swift Package Manager. Swift Package Index listing is subject to its review process.

## Features

- Request list, host and path search, failure and slow-request filters, pause, and clear.
- Request and response headers, size-limited JSON bodies, HTTP validation errors, and network errors.
- Field paths and expected types for `DecodingError`, without retaining raw error descriptions that may expose body content.
- Field-based redaction, bounded in-memory records, per-body limits, and a total body storage budget.
- Report preview and system sharing; records are stored in memory only by default.
- A local mock example covering success, 401 responses, JSON decoding failures, and timeouts. Requests pass through Alamofire without contacting a server.

## Requirements

- Validated toolchain: Xcode 27 and Swift 6.4.
- Swift 6 language mode; Alamofire **5.12.2**, which requires Swift 6.4.
- iOS 16+. The package also declares macOS 13+ for local tests and reuse; macOS UI interactions have not been validated.
- A paid Apple Developer account is not required to run in the simulator.

## Run the example

1. Open `Examples/TraceExample/TraceExample.xcodeproj` in Xcode.
2. Wait for Swift Package Manager to resolve Alamofire. The first resolution requires network access.
3. Select the **TraceExample** scheme, **Debug** configuration, and an iPhone simulator, then run.
4. The app automatically sends a group of local mock requests on its first launch. Tap **Send again** to generate another group.
5. Open `/v1/feed` to inspect the decoding failure at `items[2].title`.
6. Open the login request and confirm that the request password and response `accessToken` are redacted.

Open the example `.xcodeproj` to run the app. Opening the repository root directly exposes only the Swift package's library schemes.

The Release example does not create diagnostics objects or the panel. To run on a physical device, select your own Team in Signing & Capabilities and change the Bundle Identifier if it conflicts with an existing identifier.

## Languages

The UI, diagnostic descriptions, and shared reports support Chinese and English, following the system's preferred supported language. Other languages fall back to English. Chinese currently uses Simplified Chinese text. Restart the app after changing the system language; no manual language selection is needed in the panel.

For development, select Chinese or English under Xcode's **Edit Scheme → Run → Options → App Language**. Set it back to **System Language** after verification.

## Integrate into your app

In Xcode, choose **File → Add Package Dependencies…** and enter:

```text
https://github.com/lidongyang-Ethan/Trace.git
```

Select version **0.1.1** or later within the 0.1 series, then add the `TraceAlamofire` and `TraceUI` products. Your app also needs a direct dependency on Alamofire.

For a `Package.swift` manifest:

```swift
.package(url: "https://github.com/lidongyang-Ethan/Trace.git", .upToNextMinor(from: "0.1.1"))
```

To work with a local checkout, use Xcode's **Add Local…** and select the repository root.

```swift
import Alamofire
#if DEBUG
import TraceAlamofire
import TraceUI
#endif

// Create these in a suitable long-lived owner; do not create a Session per request.
#if DEBUG
let diagnostics = NetworkDiagnostics()
let session = Session(eventMonitors: [diagnostics.monitor])
#else
let session = Session()
#endif
```

Present the panel from your app's debug entry point:

```swift
#if DEBUG
NetworkDiagnosticsView(store: diagnostics.store)
#endif
```

The panel owns its `NavigationStack` and works well in a sheet. Requests must use the `Session` configured with the monitor. Trace does not automatically observe `AF.request`, other sessions, or other networking libraries.

## Project structure

```text
Sources/TraceCore        Record models, redaction, bounded storage, reports
Sources/TraceAlamofire   Alamofire event adapter and error classification
Sources/TraceUI          SwiftUI list, details, settings, and sharing
Tests/                  Core tests and URLProtocol integration tests
Examples/TraceExample   Runnable iOS example project
Documentation/          Design, learning, and validation notes (Chinese)
```

Use the export button in the request list to save the current search and filter results as a JSON file. Select All and clear the search to export all retained requests. The file includes captured headers and bodies with the configured redaction rules applied. Review free text before sharing.

## Tests

Run from the repository root:

```sh
swift test
```

Tests use a custom `URLProtocol` to provide deterministic responses without external APIs. Coverage includes sensitive-data redaction, body omission, pause and clear, capacity limits, concurrency, HTTP and decoding errors, cancellation, timeouts, retries, localized resources, and language fallback.

GitHub Actions runs the package tests and builds the Debug example for a specific iPhone simulator on pull requests, pushes to main, and numeric version tags. Before publishing a release, check that **Trace CI** passed for the tagged commit.

## Current limitations

- Only ordinary Alamofire `DataRequest` requests are supported. Uploads, downloads, and streaming requests are not recorded.
- HTTP errors refer to failures of the validation configured in Alamofire. A 4xx response without `.validate()` does not necessarily count as a client processing failure.
- Multiple response serializers share one record, which retains any observed failure. Starting a retry clears the previous outcome, and the final attempt determines the new outcome. Per-attempt details are not retained yet.
- Total duration includes queueing, retries, and observed serialization processing. The Diagnostics tab shows DNS, connection (including TLS), TLS, wait from request end to first byte, and download times for the last transaction of the current attempt when URLSession supplies them. JSON timing values are in seconds.
- Only parseable JSON that can be redacted by field is retained. Non-JSON, malformed JSON, and oversized bodies are omitted; raw content is not truncated and presented as safely redacted data.
- Authentication and Cookie headers, plus `password`, `token`, `accessToken`, `refreshToken`, `access_token`, `refresh_token`, `X-API-Key`, `email`, `apiKey`, `secret`, and `signature` fields, are redacted by default, case-insensitively. Additional fields can be configured. Personal information in free text and URL paths cannot be guaranteed to be redacted automatically.
- Detail and report views refresh every 250 ms and stop displaying records removed by clearing, settings changes, or capacity limits. Reports already handed to the system share sheet cannot be revoked.
- Changing settings clears existing records. Value-type snapshots already obtained by callers cannot be retroactively revoked.
- The body budget is not a process-wide memory limit. Alamofire still retains its request data. There is no event-queue backpressure mechanism, and extreme-concurrency performance has not been validated.
- The list polls snapshots every 250 ms to avoid refreshing the UI for every callback. Coalesced notifications may replace this after performance measurements.
- The project does not yet include a final app icon or store materials. It is a developer toolkit and example, not an app submitted to the App Store.

## Next steps

Start with [the first lesson](Documentation/第一课.md) (Chinese). Run and understand one request before making incremental improvements; avoid expanding every feature at once.
