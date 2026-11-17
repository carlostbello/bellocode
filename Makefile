# Common development commands. See README.md, "Build and run".
CONFIG ?= debug

.PHONY: build test fetch app run smoke plugin-test clean

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

# The opencode plugin's tests (bun) in a container; bun is never run on the Mac.
plugin-test:
	swift run ContainerDemo plugin-test Plugin

clean:
	rm -rf .build build
