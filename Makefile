# Common development commands. See README.md, "Build and run".
CONFIG ?= debug

# SwiftTerm's build plugin asks git for build metadata when these are unset, and that child wait can stall
# indefinitely under Command Line Tools (docs/reviews/deep-review-1.md, D1). Supply the pinned values.
export SWIFTTERM_BUILD_TAG ?= v1.99.3
export SWIFTTERM_BUILD_COMMIT ?= 282c3c3a932b55c129628876b70f37d993af1615
export SWIFTTERM_BUILD_BRANCH ?= HEAD
export SWIFTTERM_BUILD_DIRTY ?= false

.PHONY: build test fetch app run smoke e2e-containers e2e-exec plugin-test opencode-upgrade opencode-verify clean

build:
	swift build

test:
	swift test

fetch:
	Scripts/fetch-opencode.sh

app: fetch
	Scripts/make-app.sh $(CONFIG)

run: app
	open build/BelloCode.app

smoke: app
	build/BelloCode.app/Contents/MacOS/BelloCode --smoke-test

# The smoke test plus the containerised end-to-end run (real opencode, one prompt on a free model).
e2e-containers: app
	BELLOCODE_SMOKE_E2E=1 build/BelloCode.app/Contents/MacOS/BelloCode --smoke-test

# The smoke test plus the execution-modes end-to-end run: shared workspace, two repositories under one temporary code
# root, an agent reading across them and starting a compose stack through the filtered Docker endpoint (two prompts on
# a free model). Needs bellocode-test-ws:1 (docs/features/workspace-image.Dockerfile) and redis:7-alpine present.
e2e-exec: app
	BELLOCODE_SMOKE_EXEC=1 build/BelloCode.app/Contents/MacOS/BelloCode --smoke-test

# The opencode plugin's tests (bun) in a container; bun is never run on the Mac.
plugin-test:
	swift run ContainerDemo plugin-test Plugin

# opencode upgrades (docs/features/opencode-upgrades.md). Neither changes the pin (Scripts/opencode-version).
# Download, verify and capture a candidate's contract, and diff it against the pinned one (one free-model prompt).
opencode-upgrade:
	@test -n "$(VERSION)" || { echo "usage: make opencode-upgrade VERSION=x.y.z"; exit 2; }
	Scripts/opencode-upgrade.sh $(VERSION)

# The regression gate against a candidate: report in build/opencode-verify/<version>/REPORT.md.
opencode-verify:
	@test -n "$(VERSION)" || { echo "usage: make opencode-verify VERSION=x.y.z"; exit 2; }
	Scripts/opencode-verify.sh $(VERSION)

clean:
	rm -rf .build build
