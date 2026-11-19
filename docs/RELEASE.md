# Releasing BelloCode

BelloCode 1.0 is an internal build for one owner (docs/PLAN.md, section 0). It is **ad-hoc signed**: it is not signed
with a Developer ID certificate and not notarised, so Gatekeeper refuses to open a downloaded copy until the owner
allows it once (below).

## What 1.0 supports

- **Apple silicon (arm64) Macs only**, macOS 15 or later. `Scripts/make-app.sh` refuses to build on an Intel Mac, and
  the shared Chrome refuses to build its image on an amd64 Docker engine (its Dockerfile pins arm64 browse and Chromium
  binaries). The built-in WebKit browser preview works regardless.
- Rancher Desktop for container execution and the shared Chrome.
- The bundled opencode is the pinned version (`Scripts/opencode-version`).

## Building the handoff

```sh
make release
```

This runs `Scripts/fetch-opencode.sh`, then `Scripts/make-release.sh`, which:

1. builds the release configuration and assembles `build/BelloCode.app` (`Scripts/make-app.sh release`), signing the
   helpers and then the app, all ad-hoc (`BELLOCODE_SIGN_IDENTITY` overrides this when a real identity exists);
2. checks the bundle: marketing version from `VERSION` (1.0.0), build number (`BELLOCODE_BUILD_NUMBER`, default the
   commit count), arm64-only executables, the same kind of signature on every nested helper, and
   `codesign --verify --deep --strict`;
3. zips it with `ditto` as `build/BelloCode-1.0.0.zip`;
4. unzips that zip into a temporary folder, marks the copy quarantined as a browser download would, runs the same
   checks on it, confirms it is identical to the built app, and reports Gatekeeper's verdict
   (`spctl --assess --type execute`). For an ad-hoc build the expected verdict is **rejected**: that is what the
   owner's Mac will say too, and why the steps below exist. The app is never launched by the script.

The last lines of the output summarise the zip (size and SHA-256), version, build, opencode version, signature and the
Gatekeeper verdict. Send the zip and its SHA-256 to the owner.

Run `make test` first; `make smoke` checks the bundled server headlessly.

## Opening it on the owner's Mac

Unzip `BelloCode-1.0.0.zip` (double-click it), move `BelloCode.app` to `/Applications`, then either:

- **Finder:** open it once. macOS refuses because it cannot check the developer. On macOS 15 and later open
  **System Settings ▸ Privacy & Security**, scroll to Security, and click **Open Anyway** next to the BelloCode message,
  then confirm with your password. (On macOS 14 and earlier, Control-click or right-click the app and choose **Open**;
  macOS 15 removed that shortcut.)
- **Terminal:** remove the quarantine flag the download added, then open it normally:

  ```sh
  xattr -dr com.apple.quarantine /Applications/BelloCode.app
  open /Applications/BelloCode.app
  ```

Either way this is needed once per installed copy; updates delivered the same way need it again. Only do this for a zip
whose SHA-256 matches the one sent with it.

## Not done for 1.0

- Developer ID signing, notarisation and stapling (no enterprise certificate is set up). With one, set
  `BELLOCODE_SIGN_IDENTITY`, notarise the zip with `notarytool`, staple the app, and `make release` will report
  Gatekeeper's acceptance.
- Intel (x86_64) builds.
- A test on a clean second Mac: the script's quarantined-copy check approximates it but cannot replace opening the app
  there.
