# SnapneditCanvas

The official Swift wrapper for the [snapnedit](https://snapnedit.com) embeddable photo editor.

It runs the real editor inside a `WKWebView` and gives you an ordinary Swift async API over it — `loadImage`, `run`, `export`, `exportTo` — plus an `AsyncStream` of everything the editor reports back. No JSON, no `evaluateJavaScript`, no message-handler bookkeeping.

- **Platforms:** macOS 13+, iOS 16+
- **Version:** 0.1.0 (protocol version 1)
- **License:** MIT

---

## Install

Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/Snap-N-Edit/canvas-swift", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "SnapneditCanvas", package: "canvas-swift"),
    ]),
]
```

Or in Xcode: **File → Add Package Dependencies…** and paste the repository URL.

---

## SwiftUI

```swift
import SwiftUI
import SnapneditCanvas

struct EditorScreen: View {
    let photo: UIImage
    private let config = SnapneditCanvasConfiguration(
        credential: .publishableKey("pk_live_…", appId: "com.acme.photos")
    )

    var body: some View {
        SnapneditCanvas(configuration: config)
            .onReady { handle in
                try? await handle.loadImage(photo)
            }
            .onEvent { event in
                if case .job(let job) = event { print(job.operation, job.status) }
            }
    }
}
```

## AppKit / UIKit

```swift
import SnapneditCanvas

final class EditorViewController: UIViewController {   // NSViewController on macOS
    private var canvas: SnapneditCanvasView?

    override func viewDidLoad() {
        super.viewDidLoad()
        let config = SnapneditCanvasConfiguration(
            credential: .publishableKey("pk_live_…", appId: "com.acme.photos"),
            theme: SnapneditTheme(mode: .dark, accent: "#ff5500")
        )
        guard let canvas = try? SnapneditCanvasView(configuration: config) else { return }
        self.canvas = canvas
        canvas.frame = view.bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(canvas)

        Task {
            // Calls are QUEUED until the editor reports `ready` — no gate to write.
            try await canvas.handle.loadImage(photo)
            try await canvas.handle.run(.removeBackground)
            let png = try await canvas.handle.export(.png)
            try png.data.write(to: outputURL)
        }
    }

    deinit { canvas?.handle.destroy() }
}
```

`destroy()` matters: `WKUserContentController` retains its script-message handlers, so an editor that is only released keeps its webview alive. `SnapneditCanvasView` calls it from `deinit` as a backstop, but call it yourself when the screen goes away.

---

## Credentials

A native app has no browser origin, so it identifies itself with a **native app id** — your bundle identifier, or any short slug — written as `native:<app-id>`.

**Publishable key.** Add the app id under **dashboard → API keys → Allowed origins**, one per line:

```
https://app.example.com
native:com.acme.photos
```

```swift
.publishableKey("pk_live_…", appId: "com.acme.photos")
```

The key is public in a native app exactly as it is on the web — it ships inside your `.ipa` and anyone can unzip it. The allowlist is not an authentication boundary; it stops casual reuse of your key in someone else's app and gives you a per-surface off switch. Your real controls are the key's daily credit cap, revocation, and short-lived tokens.

**Host-minted token.** If you have a backend, mint one with `POST /embed/tokens` and pass it instead. It is short-lived, skips the app-id check, and lets you set per-end-user credit caps and an operation allowlist:

```swift
.token(try await myBackend.mintEmbedToken(for: user), appId: "com.acme.photos")
```

Answer the `tokenExpiring` event with `handle.refreshToken(_:)`. A publishable-key session re-mints itself and you can ignore it.

The credential rides the frame URL because there is no host page to hand it over from. That URL is loaded by your own webview and is nobody else's referrer — but keep it out of shared browsing history and out of your logs.

---

## Files in and out

**In** — bytes, a platform image, or an `https:` URL:

```swift
try await handle.loadImage(uiImage)                              // PNG-encoded for you
try await handle.loadImage(data: jpegBytes, mime: "image/jpeg")  // the original file, no re-encode
try await handle.loadImage(url: URL(string: "https://cdn.example/photo.jpg")!)
try await handle.addImage(data: logo, mime: "image/png", name: "logo")
```

Bytes cross as one `data:` URL that WebKit copies whole, so keep them under a few megabytes (`SnapneditLimits.recommendedMaxDataURLBytes`, 4 MB). Above that, upload the photo somewhere reachable over `https:` and pass the URL — the editor fetches it itself. An `https:` URL on the editor's own origin, a relative path, and any non-`https:` scheme are refused with `invalid_input`.

**Out** — `export` hands you the file:

```swift
let result = try await handle.export(.png)                                   // Data + mime + width/height
let jpg = try await handle.export(.jpg, options: .init(targetWidth: 1600, quality: 0.85))
let pdf = try await handle.export(.pdf, options: .init(allPages: true))
```

**Out, without the round trip** — for anything large, `exportTo` uploads straight from the webview to your bucket and the bytes never enter your process:

```swift
// A presigned url your backend minted.
try await handle.exportTo(.presigned(url: uploadURL, headers: ["content-type": "image/png"]))

// Or a storage destination already saved on your snapnedit account.
let destinations = try await handle.listDestinations()
let result = try await handle.exportTo(.savedDestination(id: destinations[0].id, format: .webp))
print(result.bucket ?? "", result.key ?? "", result.status)
```

Your bucket needs a CORS rule allowing `PUT` from the **editor frame's** origin (`https://snapnedit.com`), not your app.

---

## Events

Every event, as an `AsyncStream` — each access returns an independent stream, and `ready` is replayed to a late subscriber:

```swift
for await event in handle.events {
    switch event {
    case .ready(let version):            print("editor \(version)")
    case .change(let dirty, _):          saveButton.isEnabled = dirty
    case .selection(let ids, _):         inspector.show(ids)
    case .job(let job):                  spinner.isAnimating = job.status == .started
    case .export(let export):            share(export.result.data)
    case .save(let save):                persist(save.document)
    case .close:                         dismiss()
    case .error(let error):              report(error)
    case .tokenExpiring:                 try? handle.refreshToken(await mintToken())
    case .unknown(let name, let data):   log(name, data)
    }
}
```

Or a closure (`handle.onEvent = { … }`) or a delegate (`handle.delegate`). An `error` **before** `ready` is a fatal boot failure — a refused key or app id; after `ready` it is informational.

---

## Methods

Every method in the protocol, in Swift style. Calls issued before the editor is ready are queued, in order.

| Swift | Editor method | Notes |
| --- | --- | --- |
| `loadImage(_:)` / `loadImage(data:mime:)` / `loadImage(url:)` | `loadImage` | Replaces the document |
| `addImage(…)` | `addImage` | Adds a layer |
| `loadDocument(_:)` / `setDocument(_:)` | `loadDocument` | |
| `getDocument()` | `getDocument` | Returns `JSONValue` |
| `getPages()` | `getPages` | |
| `newDocument(width:height:)` | `newDocument` | |
| `export(_:options:)` | `export` | `Data` + mime + size |
| `exportTo(_:options:)` | `exportTo` | Presigned url or saved destination |
| `listDestinations()` | `listDestinations` | |
| `run(_:params:)` | `run` | Returns the job id, credits and duration |
| `openTool(_:)` / `openTool(rail:)` | `openTool` | |
| `undo()` / `redo()` | `undo` / `redo` | |
| `select(_:)` | `select` | |
| `getState()` | `getState` | |
| `setTheme(_:)` / `setFeatures(_:)` / `setLocale(_:)` | same | |
| `refreshToken(_:)` | `refresh-token` | Not queued — sent immediately |
| `call(_:_:)` | any | Escape hatch for a method a newer editor added |

`loadImage`, `addImage`, `export`, `exportTo` and `run` are long-running: they get 180s by default, everything else 30s, and the boot 60s. Change them with `SnapneditTimeouts`.

---

## Errors

Everything throws `SnapneditError`, whose `code` you can switch on:

```swift
do {
    try await handle.run(.magicEraser)
} catch let error as SnapneditError {
    switch error.code {
    case .maskRequired:    try await handle.openTool(.magicEraser)
    case .paymentRequired: presentTopUp()
    case .uploadFailed:    print("bucket said \(error.uploadStatus ?? 0)")
    default:               report(error)
    }
}
```

| Code | Meaning |
| --- | --- |
| `invalid_input` | Bad arguments — a malformed url, an unknown format, a header off the allowlist |
| `unsupported_mime` | Not an image type the operation accepts |
| `too_large` | Over the upload ceiling |
| `not_found` | No such asset, job or destination |
| `input_fetch_failed` | The editor could not fetch the url you gave it |
| `provider_failed` | A model ran and failed |
| `provider_exhausted` | Every provider for the operation failed |
| `rate_limited` | A rate limit was hit |
| `bot_check_failed` | Bot protection refused the request |
| `unauthorized` | Missing, malformed or revoked credential |
| `forbidden` | Authenticated, but not allowed |
| `payment_required` | Out of credits |
| `internal` | Something broke on our side |
| `not_ready` | A call reached a session that never became usable |
| `mask_required` | A mask-guided operation reached `run` — open the tool instead |
| `timeout` | The call, or the boot, missed its deadline |
| `origin_denied` | The key does not allow this `native:<app-id>` |
| `destroyed` | The handle was destroyed while the call was in flight |
| `token_expired` | The session token ran out and nothing replaced it |
| `network_error` | An `exportTo` upload got no response — bucket CORS, DNS, a redirect |
| `upload_failed` | The bucket answered non-2xx; the status is in `error.uploadStatus` |
| `unsupported` | The deployed editor does not implement that method — your app is newer |

`SnapneditErrorCode` is a `RawRepresentable` struct, not an enum, so a code introduced by a newer editor arrives intact rather than failing to decode.

---

## How it works

The editor is loaded as the top-level document of a `WKWebView`:

```
https://snapnedit.com/embed?transport=native&origin=native:<app-id>&key=pk_live_…
```

Out, the frame posts JSON strings to `window.webkit.messageHandlers.snapnedit.postMessage(json)`. In, this package evaluates `window.SnapneditNativeBridge.receive(<literal>)`. Envelopes are `{ snapnedit: 1, type: 'call' | 'result' | 'event', id, payload }`, matched by `id`. Blobs, which JSON cannot carry, arrive as `{ dataUrl, mime, bytes }` and are decoded back into `Data` for you.

The whole contract is machine-readable in [`protocol.json`](https://github.com/Snap-N-Edit/embed/blob/main/protocol.json); a copy ships in this package's tests, and `ProtocolConformanceTests` fails if any method, event or error code here falls behind it.

---

## Testing

```sh
swift build
swift test          # protocol-layer tests, no WKWebView, no network
```

There is a second target, `SnapneditCanvasIntegrationTests`, that drives a real `WKWebView` against a real snapnedit stack. It skips itself unless you point it at one:

```sh
SNAPNEDIT_E2E_URL=http://localhost:3000 swift test --filter Integration
```

---

## Related

- [Native embedding guide](https://snapnedit.com/docs/embed-native) — the same protocol, hand-rolled
- [`@snapnedit/embed`](https://github.com/Snap-N-Edit/embed) — the web loader
- [`@snapnedit/sdk`](https://github.com/Snap-N-Edit/sdk) — the REST API client
- [`@snapnedit/mcp`](https://github.com/Snap-N-Edit/mcp) — the MCP server

Developed in the snapnedit monorepo and mirrored here; issues welcome.
