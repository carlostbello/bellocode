# BelloCode shared browser: Chromium + the browse extension + browse's relay and MCP server + Xvnc/websockify, one
# Linux container (docs/features/shared-browser.md). Built locally by BelloCode with Rancher's `docker buildx build
# --load` (images are built locally by policy); every pinned input is a build argument from versions.env, so a change
# changes the input hash and BelloCode rebuilds. No `# syntax` line: the built-in frontend handles secret mounts and no
# frontend image has to be pulled.
#
# The extension packing key is a BuildKit secret (`--secret id=extkey,env=…`): it exists only while the pack step runs
# and never reaches a layer, the build cache's exported image or the repository. The same key gives the same extension
# ID on every rebuild, so the profile stays paired.
ARG BASE_IMAGE

# ---- fetch: pinned downloads, verified by SHA-256 (nothing executes from them here) -----------------------------------
FROM ${BASE_IMAGE} AS fetch
ARG BROWSE_VERSION
ARG BROWSE_TGZ_SHA256
ARG BROWSE_EXT_SHA256
ARG NOVNC_VERSION
ARG NOVNC_SHA256
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip && rm -rf /var/lib/apt/lists/*
RUN set -eu; \
    curl -fsSL --retry 3 -o /tmp/browse.tgz "https://registry.npmjs.org/@opencode/browse-linux-arm64/-/browse-linux-arm64-${BROWSE_VERSION}.tgz"; \
    echo "${BROWSE_TGZ_SHA256}  /tmp/browse.tgz" | sha256sum -c -; \
    mkdir /tmp/b && tar -xzf /tmp/browse.tgz -C /tmp/b; \
    install -D -m 0755 "$(find /tmp/b -type f -name browse | head -1)" /out/usr/local/bin/browse; \
    curl -fsSL --retry 3 -o /tmp/ext.zip "https://anoma.ly/release/browse/files/${BROWSE_EXT_SHA256}/browse-extension-${BROWSE_VERSION}.zip"; \
    echo "${BROWSE_EXT_SHA256}  /tmp/ext.zip" | sha256sum -c -; \
    mkdir -p /out/opt/browse-ext && unzip -q /tmp/ext.zip -d /out/opt/browse-ext; \
    cd /tmp && apt-get update && apt-get download "novnc=${NOVNC_VERSION}" && rm -rf /var/lib/apt/lists/*; \
    echo "${NOVNC_SHA256}  $(ls /tmp/novnc_*.deb)" | sha256sum -c -; \
    dpkg-deb -x /tmp/novnc_*.deb /tmp/novnc; \
    mkdir -p /out/usr/share && cp -r /tmp/novnc/usr/share/novnc /out/usr/share/novnc; \
    rm -rf /out/usr/share/novnc/utils /out/usr/share/novnc/vnc_lite.html

# ---- runtime: Debian packages, Node removed, docs/locales trimmed ----------------------------------------------------
FROM ${BASE_IMAGE} AS runtime
ARG CHROMIUM_VERSION
ARG CHROMIUM_SHA256
ARG CHROMIUM_COMMON_SHA256
ARG CHROMIUM_SANDBOX_SHA256
ARG CHROMIUM_LOCALES="en-US en-GB es es-419 fr de pt-BR"
RUN set -eu; \
    apt-get update; \
    mkdir /tmp/debs && cd /tmp/debs; \
    apt-get download "chromium=${CHROMIUM_VERSION}" "chromium-common=${CHROMIUM_VERSION}" "chromium-sandbox=${CHROMIUM_VERSION}"; \
    echo "${CHROMIUM_SHA256}  $(ls chromium_*.deb)" | sha256sum -c -; \
    echo "${CHROMIUM_COMMON_SHA256}  $(ls chromium-common_*.deb)" | sha256sum -c -; \
    echo "${CHROMIUM_SANDBOX_SHA256}  $(ls chromium-sandbox_*.deb)" | sha256sum -c -; \
    apt-get install -y --no-install-recommends ./*.deb \
      tigervnc-standalone-server tigervnc-tools websockify python3-numpy libnss3-tools socat \
      fonts-liberation fonts-noto-core ca-certificates tini procps; \
    cd / && rm -rf /tmp/debs /var/lib/apt/lists/* /var/cache/apt/*.bin; \
    # No Node in the final image (the relay, MCP server and viewer do not need it).
    rm -rf /usr/local/bin/node /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack /usr/local/bin/yarn* \
      /usr/local/lib/node_modules /usr/local/include/node /usr/local/share/doc/node /opt/yarn-*; \
    userdel -r node 2>/dev/null || true; \
    # Docs, man pages and message catalogues; Chromium UI locales outside CHROMIUM_LOCALES.
    rm -rf /usr/share/doc/* /usr/share/man/* /usr/share/info/* /usr/share/lintian; \
    find /usr/share/locale -mindepth 1 -maxdepth 1 ! -name 'en*' -exec rm -rf {} +; \
    for f in /usr/lib/chromium/locales/*.pak; do \
      n=$(basename "$f" .pak); case " ${CHROMIUM_LOCALES} " in *" $n "*) ;; *) rm -f "$f" "$f.info" ;; esac; \
    done; \
    useradd -m -u 1001 -s /bin/sh browser; \
    mkdir -p /data /etc/chromium/policies/managed /etc/bellocode/certs && chown browser:browser /data
COPY --from=fetch /out/ /

# ---- pack: the CRX3 signed with the installation's key (BuildKit secret), its ID, the update manifest and policy -----
FROM runtime AS pack
COPY policy.json /tmp/policy.json
RUN apt-get update && apt-get install -y --no-install-recommends openssl && rm -rf /var/lib/apt/lists/*
RUN --mount=type=secret,id=extkey,required=true set -eu; \
    d=/opt/browse-crx; mkdir -p "$d/src"; cp -r /opt/browse-ext/. "$d/src/"; \
    p=$(mktemp -d); \
    chromium --no-sandbox --user-data-dir="$p" --pack-extension="$d/src" --pack-extension-key=/run/secrets/extkey >/dev/null 2>&1 || true; \
    test -s "$d/src.crx"; mv "$d/src.crx" "$d/browse.crx"; rm -rf "$d/src" "$p"; \
    id=$(openssl pkey -in /run/secrets/extkey -pubout -outform DER | sha256sum | cut -c1-32 | tr 0-9a-f a-p); \
    test ${#id} = 32; echo "$id" > "$d/id"; \
    ver=$(python3 -I -c 'import json;print(json.load(open("/opt/browse-ext/manifest.json"))["version"])'); \
    printf '<?xml version="1.0"?><gupdate xmlns="http://www.google.com/update2/response" protocol="2.0"><app appid="%s"><updatecheck codebase="file://%s/browse.crx" version="%s"/></app></gupdate>\n' "$id" "$d" "$ver" > "$d/update.xml"; \
    python3 -I -c 'import json,sys;p=json.load(open("/tmp/policy.json"));p["ExtensionInstallBlocklist"]=["*"];p["ExtensionInstallForcelist"]=[sys.argv[1]];json.dump(p,open("/out-policy.json","w"),indent=1)' "$id;file://$d/update.xml"; \
    chmod -R a+rX "$d"

# ---- final: one flattened layer (no Node, no unpacked extension, no packing key) --------------------------------------
FROM scratch
COPY --from=runtime / /
COPY --from=pack /opt/browse-crx /opt/browse-crx
COPY --from=pack /out-policy.json /etc/chromium/policies/managed/bellocode.json
COPY entrypoint.sh /usr/local/bin/bellocode-browser
COPY ctl.sh /usr/local/bin/bellocode-browser-ctl
COPY browse-mcp /usr/local/bin/browse-mcp
COPY view.html /usr/share/novnc/bellocode.html
USER browser
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    HOME=/tmp/home DISPLAY=:1 LANG=C.UTF-8 \
    XDG_CONFIG_HOME=/data/xdg/config XDG_DATA_HOME=/data/xdg/data XDG_STATE_HOME=/data/xdg/state XDG_CACHE_HOME=/tmp/cache \
    OPENCODE_BROWSER_AUTO_UPDATE=off OPENCODE_BROWSER_AGENT_WINDOW=current OPENCODE_BROWSER_PORT=19988
VOLUME /data
STOPSIGNAL SIGTERM
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/bellocode-browser"]
LABEL app.bellocode.browser="1" org.opencontainers.image.title="BelloCode shared browser"
