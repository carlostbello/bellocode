# Common development commands. See README.md, "Build and run".
CONFIG ?= debug

.PHONY: build test fetch app run smoke clean

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

clean:
	rm -rf .build build
