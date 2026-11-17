# Common development commands. See README.md, "Build and run".
CONFIG ?= debug

.PHONY: build test fetch app run smoke e2e-containers plugin-test clean

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

# The opencode plugin's tests (bun) in a container; bun is never run on the Mac.
plugin-test:
	swift run ContainerDemo plugin-test Plugin

clean:
	rm -rf .build build
