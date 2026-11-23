# Shared browser image

The build context of the shared Chromium container (see
[docs/features/shared-browser.md](../../docs/features/shared-browser.md)). `Scripts/make-app.sh` bundles the eight files
listed in `BrowserImageContext.fileNames` as `Contents/Resources/browser-image/`; BelloCode builds the image locally with
Rancher Desktop's `docker buildx`. This README is not part of the build context's input hash and is not copied into the
image. `make browser-verify` is the regression gate for any change here.

| File | Purpose |
| --- | --- |
| `Dockerfile` | Multi-stage build: pinned Debian Chromium, noVNC, browse and its extension, flattened onto `scratch` |
| `versions.env` | Every pinned input (base image digest, package versions, SHA-256 sums) |
| `entrypoint.sh`, `ctl.sh` | Container start-up and the control commands BelloCode runs with `docker exec` |
| `browse-mcp` | Starts browse's MCP server inside the container |
| `policy.json` | Chromium managed policy (installs the browse extension) |
| `view.html` | The noVNC viewer page BelloCode's panel loads |
| `seccomp-chromium.json` | Seccomp profile the container runs with (below) |
| `make-seccomp.py` | Regenerates `seccomp-chromium.json` from Docker's default profile |

## Licence of `seccomp-chromium.json`

`seccomp-chromium.json` is a derivative of `seccomp/default.json` from
[moby/profiles](https://github.com/moby/profiles), licensed under the Apache License 2.0. It matches upstream commit
`9ee3204f0d0cfa19ca2c6a7b0fcf5a2b353954ae` except for one appended `syscalls` entry ("BelloCode G7: Chromium namespace
sandbox") that allows `clone`, `unshare`, `setns` and `chroot` without `CAP_SYS_ADMIN`, so Chromium can create its own
sandbox namespaces. No capability is added. `make-seccomp.py` makes exactly that change:

```sh
python3 -I make-seccomp.py default.json seccomp-chromium.json
```

The full licence text and this notice are in [Scripts/notices/moby-seccomp.txt](../../Scripts/notices/moby-seccomp.txt);
`Scripts/make-app.sh` copies it into the app bundle (`Contents/Resources/Acknowledgements/moby-profiles-seccomp.txt`).
The identical copy in `Spikes/ChromeBrowse/` is under the same licence.

The image itself removes `/usr/share/doc` to save space, which drops the Debian packages' copyright files. That is
acceptable while the image is only built locally and never redistributed; restore them before publishing the image.
