# G4 Packaging: SwiftPM-built, re-signed bundle (2026-11-16)

Result: **pass for local, ad-hoc signed builds.** The "runs a turn on a free model" part of the gate was not run
(the brief for this package forbids sending prompts); it belongs to the first OpenCodeKit or G2 package.

## Verified

- `swift build` and `swift test` on Swift 6.4, Command Line Tools only, macOS 27, Apple Silicon (10 libraries,
  1 executable, 10 test targets, Swift 6 mode).
- An SwiftPM executable links AppKit and SwiftUI, and from the bundle runs as a regular app: Dock icon, menu bar,
  main window. Checked with `open build/BelloCode.app` (not a Finder double-click), `NSWorkspace` (activation policy regular) and
  `CGWindowListCopyWindowInfo` (one on-screen window, layer 0); quit through the standard Apple Event quit.
  Window frame and split positions persist (`defaults read com.bellocode.app`).
- `Scripts/fetch-opencode.sh` downloads `https://opencode.ai/files/bin/2.3.0/opencode-darwin-arm64.zip`, checks
  the archive SHA-256 from the Homebrew tap formula, and the extracted binary matches the Homebrew binary
  (SHA-256 `9f3147ca…f52`). The `--local` fallback and the download cache were exercised too.
- `Scripts/make-app.sh` signs inside-out with `codesign --options runtime`: opencode with its upstream entitlements
  (allow-jit, allow-unsigned-executable-memory, disable-executable-page-protection, allow-dyld-environment-variables,
  disable-library-validation), then rg, then the app. `codesign --verify --deep --strict` passes.
- The re-signed opencode runs under the hardened runtime. `BelloCode --smoke-test` from the release bundle:

```
smoke: launched opencode pid 95024
smoke: ready line {"url":"http://127.0.0.1:56551"} after 122 ms
smoke: GET /api/info without credentials -> 401 (as expected)
smoke: GET /api/info with Basic auth -> 200 version 2.3.0 pid 95024 after 131 ms
smoke: closed stdin; server exited with status 0 after 6 ms
smoke: PASS
```

## Numbers

| Measure | Value |
| --- | --- |
| Bundle size | 220 MB (opencode 213 MB, rg 6.2 MB, app executable 320 KB, icon 104 KB) |
| Ready line after launch | 84 ms warm, 122 ms on the first run after re-signing |
| Authenticated `/api/info` 200 after launch | 92 ms warm |
| Exit after stdin closes | 6 ms |
| Whole `--smoke-test` process | 0.12 s warm; about 1.3 s on the first run after re-signing (system scan of the new binary) |
| `fetch-opencode.sh` from scratch / `make-app.sh` incremental | 2.8 s / 3.5 s |

## Not verified

- Developer ID signing, secure timestamp, notarization and Gatekeeper on a downloaded (quarantined) copy: no
  identity on this machine. `spctl -a` rejects the ad-hoc bundle, as expected. `make-app.sh` honours
  `BELLOCODE_SIGN_IDENTITY` but that path is untested.
- Screenshots and menu inspection: `screencapture` fails ("could not create image from display") and System Events
  timed out, so Screen Recording and Automation permissions are not granted to this shell.
- Bundled rg is Homebrew's (links `/opt/homebrew/opt/pcre2`): runs here only. Follow-up: pin a static release.

## Toolchain surprises

- **XCTest is not available** (`unable to resolve module dependency: 'XCTest'`). Use Swift Testing.
- **Swift Testing needs a workaround**: the default `swiftbuild` build system fails with "plugin for module
  'TestingMacros' not found". `Package.swift` adds `-plugin-path
  /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing` to test targets when that directory
  exists. `--build-system native` is not an alternative: it cannot find the `Testing` module at all.
- Every link step warns `search path '/Library/Developer/CommandLineTools/Developer/Library/Frameworks' not found`
  (and `.../Developer/usr/lib`). The toolchain adds these paths itself; harmless, and nothing in the package can fix it.
