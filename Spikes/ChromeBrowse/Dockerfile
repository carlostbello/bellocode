# G7 spike: Chromium + the browse extension + browse's relay/MCP server in one Linux arm64 container,
# with a VNC/noVNC live view. Nothing is published; BelloCode reaches ports through its loopback forwarder.
# Build: docker buildx build --load --label bellocode.spike=g7 -t bellocode-g7-browser Spikes/ChromeBrowse
# Docker Hub pulls time out inside this Rancher VM (G7 run), so the spike uses a Debian 12 image already present.
# Production: an approved, digest-pinned debian:trixie-slim (or company base) from the allowed registry.
ARG DEBIAN=node:22-bookworm-slim

FROM ${DEBIAN} AS fetch
ARG BROWSE_VERSION=0.1.5
# npm tarball of @opencode/browse-linux-arm64 (SHA-256 of the .tgz, checked here) and the extension release zip
# (content-addressed by its SHA-256 at anoma.ly/release). Both pinned; no install script runs.
ARG BROWSE_TGZ_SHA256=0b550e8b6623994a947bc998704b4bc5e796e307323de5f947cd4abd7c7d7dab
ARG EXT_SHA256=5527b8e2865068ebd4060c6274ce7633bc06e1d2080fd19974a1cf9c7a7fe18d
# The release zip has no manifest "key", so it would load with a path-derived ID the relay rejects. The key from
# public/manifest.json at browse e1e3b75 gives the stable unpacked ID afeafocngkodbmaipcngoamamfmekgfo the relay trusts.
ARG EXT_KEY=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAjWdgsBDUPCHO2u5bq3/Us1sLm+kiehLZBL0HIu3stwivGW+bgCDsD8KAEMFJcY04u3iudffTeEGdEe8pQfL7BSNRvyslszmvJrsoP7bVUKXrnRTw3CUsRjnwbqMoMElwegiCFUXPnqQ9ZeA2NGEhmWMyDXqqZxOo0z2q66GTgz9McbXOBK2QXYBPjUWxud814wSrE1lIQ2G58nQVeZenI3/PXZ4f1SACn6SdkiCR44NZwz89I1ISxftongLDED/1dlnivqJBzAtN1s2i+jWplLtOmLJJkh1LQ2jP3gWvYY1zT2RHJIw874SSrrhFt4Hguvo/L0Ge7ixvGp5tDAP2wwIDAQAB
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl unzip jq && rm -rf /var/lib/apt/lists/*
RUN set -eu; \
    curl -fsSL -o /tmp/browse.tgz "https://registry.npmjs.org/@opencode/browse-linux-arm64/-/browse-linux-arm64-${BROWSE_VERSION}.tgz"; \
    echo "${BROWSE_TGZ_SHA256}  /tmp/browse.tgz" | sha256sum -c -; \
    mkdir /tmp/b && tar -xzf /tmp/browse.tgz -C /tmp/b; \
    install -m 0755 "$(find /tmp/b -type f -name browse | head -1)" /usr/local/bin/browse; \
    curl -fsSL -o /tmp/ext.zip "https://anoma.ly/release/browse/files/${EXT_SHA256}/browse-extension-${BROWSE_VERSION}.zip"; \
    echo "${EXT_SHA256}  /tmp/ext.zip" | sha256sum -c -; \
    mkdir -p /opt/browse-ext && unzip -q /tmp/ext.zip -d /opt/browse-ext; \
    jq --arg key "$EXT_KEY" '. + {key: $key}' /opt/browse-ext/manifest.json > /tmp/m.json && mv /tmp/m.json /opt/browse-ext/manifest.json

FROM ${DEBIAN}
RUN apt-get update && apt-get install -y --no-install-recommends \
      chromium chromium-sandbox tigervnc-standalone-server novnc websockify libnss3-tools \
      fonts-liberation fonts-noto-core ca-certificates curl tini procps jq xclip openssl \
    && rm -rf /var/lib/apt/lists/*
COPY --from=fetch /usr/local/bin/browse /usr/local/bin/browse
COPY --from=fetch /opt/browse-ext /opt/browse-ext
COPY entrypoint.sh /usr/local/bin/bellocode-browser
COPY policy.json /tmp/policy.json
# Policy install (works with "every other extension blocked"): pack the extension as a CRX3 with a key made for this
# build only, install it from a local update manifest, and delete the key. Its ID goes to /opt/browse-crx/id and, at
# run time, to OPENCODE_BROWSER_EXTENSION_ORIGINS so the relay accepts it. (Unpacked --load-extension is refused
# under ExtensionInstallBlocklist ["*"]; see docs/spikes/G7/extension-loading.txt.)
RUN set -eu; d=/opt/browse-crx; mkdir -p "$d/src"; cp -r /opt/browse-ext/. "$d/src/"; \
    jq 'del(.key)' /opt/browse-ext/manifest.json > "$d/src/manifest.json"; \
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /tmp/k.pem 2>/dev/null; \
    p=$(mktemp -d); chromium --no-sandbox --user-data-dir="$p" --pack-extension="$d/src" --pack-extension-key=/tmp/k.pem >/dev/null 2>&1 || true; \
    test -s "$d/src.crx"; mv "$d/src.crx" "$d/browse.crx"; rm -rf "$d/src" "$p"; \
    id=$(openssl rsa -in /tmp/k.pem -pubout -outform DER 2>/dev/null | sha256sum | cut -c1-32 | tr 0-9a-f a-p); rm -f /tmp/k.pem; \
    echo "$id" > "$d/id"; \
    printf '<?xml version="1.0"?><gupdate xmlns="http://www.google.com/update2/response" protocol="2.0"><app appid="%s"><updatecheck codebase="file://%s/browse.crx" version="%s"/></app></gupdate>\n' "$id" "$d" "$(jq -r .version /opt/browse-ext/manifest.json)" > "$d/update.xml"; \
    mkdir -p /etc/chromium/policies/managed; \
    jq --arg f "$id;file://$d/update.xml" '. + {ExtensionInstallBlocklist: ["*"], ExtensionInstallForcelist: [$f]}' /tmp/policy.json > /etc/chromium/policies/managed/bellocode.json; \
    rm /tmp/policy.json; chmod -R a+rX "$d"
COPY browse-mcp /usr/local/bin/browse-mcp
RUN useradd -m -u 1001 -s /bin/bash browser && mkdir -p /data && chown browser:browser /data
USER browser
ENV HOME=/home/browser DISPLAY=:1 \
    XDG_CONFIG_HOME=/data/xdg/config XDG_DATA_HOME=/data/xdg/data XDG_STATE_HOME=/data/xdg/state XDG_CACHE_HOME=/data/xdg/cache \
    OPENCODE_BROWSER_AUTO_UPDATE=off OPENCODE_BROWSER_AGENT_WINDOW=current
VOLUME /data
EXPOSE 6080
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/bellocode-browser"]
LABEL bellocode.spike=g7 org.opencontainers.image.title="BelloCode G7 browser"
