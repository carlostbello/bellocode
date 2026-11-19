<img src="assets/icon.svg" width="64" height="64" alt="">

# BelloCode

Created in [T3 Code](https://t3.codes).

A native macOS app (Swift 6, AppKit + SwiftUI, macOS 15+) that wraps a bundled opencode v2 server.
See [docs/PLAN.md](docs/PLAN.md) and [AGENTS.md](AGENTS.md).

## Build and run

Requires Swift 6.4 (Command Line Tools are enough; Xcode is not needed) on Apple Silicon. BelloCode 1.0 is arm64
only: `Scripts/make-app.sh` refuses an Intel Mac, and the shared Chrome image refuses an amd64 engine
(docs/RELEASE.md).

```sh
swift build                     # build all modules
swift test                      # run the Swift Testing suites
Scripts/fetch-opencode.sh       # fetch the pinned opencode (Scripts/opencode-version) into Vendor/
Scripts/make-app.sh [debug|release]   # assemble and ad-hoc sign build/BelloCode.app
open build/BelloCode.app        # launch
build/BelloCode.app/Contents/MacOS/BelloCode --smoke-test   # headless check of the bundled server
```

`make build`, `make test`, `make app`, `make run` and `make smoke` wrap the same commands. `make release` builds the
owner handoff (`build/BelloCode-<version>.zip`) and checks a copy unzipped from it; see docs/RELEASE.md.

Tests use Swift Testing (`import Testing`, `@Test`); XCTest is not available with Command Line Tools only.
The linker prints `search path ... not found` warnings for Command Line Tools paths; they are harmless.
