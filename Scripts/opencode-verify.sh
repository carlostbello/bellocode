#!/usr/bin/env bash
# Regression gate for a candidate opencode (docs/features/opencode-upgrades.md). Does not change the pin.
#
#   Scripts/opencode-verify.sh <version> [--quick]         (make opencode-verify VERSION=x.y.z)
#
# Runs, with BELLOCODE_OPENCODE_VERSION=<version> (OpenCodePin), against Vendor/opencode/<version>/opencode and
# Contracts/opencode-<version>/ (both from `make opencode-upgrade`):
#   the contract diff summary, the whole default test suite (recorded-stream decoders and the real-binary suites that
#   run by default), the mock-vs-real contract comparison, every opt-in real-binary suite, the Rancher Desktop suites,
#   the plugin tests (bun in a container), the browser bridge attach test, an app bundle of the candidate, `--smoke-test`
#   (with the isolation self-check) and the containerised end-to-end run.
# Writes build/opencode-verify/<version>/REPORT.md and report.json, plus one log per area.
#
# Model prompts, all on zero-cost built-in models: G2 1, orchestration 5, extras 7, GitLab 3, prompt retry 2, shell
# e2e 2, container e2e 2: at most 22 per run (`--quick` skips the prompting suites: 0). Every server runs in a
# temporary sandbox; Rancher Desktop is used as it is (its settings are never read or changed).

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 <x.y.z> [--quick]" >&2; exit 2; }
QUICK=0
[[ "${2:-}" == "--quick" ]] && QUICK=1
PIN="$(tr -d '[:space:]' < "$ROOT/Scripts/opencode-version")"
OUT="$ROOT/build/opencode-verify/$VERSION"
APP="$OUT/BelloCode.app"
export BELLOCODE_OPENCODE_VERSION="$VERSION"
export SWIFTTERM_BUILD_TAG="${SWIFTTERM_BUILD_TAG:-v1.99.3}"
export SWIFTTERM_BUILD_COMMIT="${SWIFTTERM_BUILD_COMMIT:-282c3c3a932b55c129628876b70f37d993af1615}"
export SWIFTTERM_BUILD_BRANCH="${SWIFTTERM_BUILD_BRANCH:-HEAD}"
export SWIFTTERM_BUILD_DIRTY="${SWIFTTERM_BUILD_DIRTY:-false}"

say() { echo "opencode-verify: $*"; }
rm -rf "$OUT"
mkdir -p "$OUT/logs"
RESULTS="$OUT/results.tsv"
: > "$RESULTS"
cd "$ROOT"

[[ -d "Contracts/opencode-$VERSION" ]] || { echo "opencode-verify: no Contracts/opencode-$VERSION; run make opencode-upgrade VERSION=$VERSION" >&2; exit 1; }
Scripts/fetch-opencode.sh > "$OUT/logs/fetch.log" 2>&1 || { echo "opencode-verify: Vendor/opencode/$VERSION is missing or does not match Scripts/opencode-checksums (see $OUT/logs/fetch.log)" >&2; exit 1; }

record() { # area status prompts seconds summary
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$RESULTS"
  say "$2  $1  ($5)"
}

# A Swift Testing run passes only when it ran at least one test and none failed or hit a time limit. Swift Testing
# counts a skipped test as passed, so an opt-in area also fails when any of its tests was skipped (its gate was off or
# a prerequisite missing); the default suite may skip opt-in tests.
swift_summary() { # log allow-skips
  # `swift test` runs one test bundle after another, each ending with its own "Test run with …" line; a bundle that
  # crashes prints none and makes SwiftPM report "exited with unexpected signal".
  local tests failed runs skipped crashed
  runs="$(grep -cE "Test run with [0-9]+ tests?" "$1")"
  [[ "$runs" -gt 0 ]] || { echo "no Swift Testing summary"; return 1; }
  tests="$(grep -oE "Test run with [0-9]+ tests?" "$1" | awk '{ n += $4 } END { print n + 0 }')"
  failed="$(grep -E "Test run with [0-9]+ tests?.* failed" "$1" | grep -oE "with [0-9]+ tests?" | awk '{ n += $2 } END { print n + 0 }')"
  skipped="$(grep -cE "➜ Test .* skipped" "$1")"
  crashed="$(grep -cE "exited with unexpected signal|Fatal error" "$1")"
  echo "$tests tests in $runs bundles, $failed in failing runs, $skipped skipped, $crashed crashed"
  [[ "$tests" -gt 0 && "$failed" == 0 && "$crashed" == 0 ]] || return 1
  [[ "$2" == 1 || "$skipped" == 0 ]]
}

run_area() { # area prompts env-assignments... -- command...
  local area="$1" prompts="$2"; shift 2
  local envs=()
  while [[ "$1" != "--" ]]; do envs+=("$1"); shift; done
  shift
  local log="$OUT/logs/$area.log" started status summary
  started=$(date +%s)
  if env ${envs[@]+"${envs[@]}"} "$@" > "$log" 2>&1; then status=0; else status=$?; fi
  local seconds=$(( $(date +%s) - started ))
  if [[ "$1" == "swift" && "$2" == "test" ]]; then
    local allow_skips=0
    [[ "$area" == "unit-and-recorded-contract" ]] && allow_skips=1
    if summary="$(swift_summary "$log" "$allow_skips")" && [[ $status == 0 ]]; then record "$area" PASS "$prompts" "$seconds" "$summary"
    else record "$area" FAIL "$prompts" "$seconds" "${summary:-exit $status}"; fi
  else
    summary="$(grep -E "PASS|FAIL|passed|failed|error" "$log" | tail -1 | cut -c1-160)"
    if [[ $status == 0 ]]; then record "$area" PASS "$prompts" "$seconds" "${summary:-exit 0}"
    else record "$area" FAIL "$prompts" "$seconds" "${summary:-exit $status}"; fi
  fi
}

skip_area() { record "$1" SKIP 0 0 "$2"; }

say "candidate $VERSION (pin $PIN); logs in ${OUT#"$ROOT"/}/logs"

# 1. Contract diff (informational: the tests below decide). The impact list names the Swift consumers.
DIFF="Contracts/opencode-$VERSION/upgrade-diff.json"
if [[ -f "$DIFF" ]]; then
  impact="$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(len(d["impact"]), "changes affecting BelloCode,", len(d["endpoints"]), "endpoint,", len(d["schemas"]), "schema changes")' "$DIFF")"
  record "contract-diff" INFO 0 0 "$impact (Contracts/opencode-$VERSION/UPGRADE-DIFF.md)"
else
  record "contract-diff" INFO 0 0 "no upgrade-diff.json (candidate is the pin)"
fi

# 2. Build once; every test area below runs the built tests.
run_area build 0 -- swift build --build-tests
grep -q $'^build\tPASS' "$RESULTS" || { say "build failed; stopping"; }

T=(swift test --skip-build)
if grep -q $'^build\tPASS' "$RESULTS"; then
  run_area unit-and-recorded-contract 0 -- "${T[@]}"
  run_area mock-vs-real-contract 0 BELLOCODE_CONTRACT_REAL=1 -- "${T[@]}" --filter "RealBinaryContract"
  run_area agent-contract-real 0 BELLOCODE_CONTRACT_REAL=1 -- "${T[@]}" --filter "AgentRealBinary"
  run_area browser-bridge-attach 0 BELLOCODE_CONTRACT_REAL=1 -- "${T[@]}" --filter "BrowserAttachRealBinary"
  run_area permission-policy-real 0 BELLOCODE_POLICY_REAL=1 -- "${T[@]}" --filter "PolicyRealBinary"
  run_area containers-live 0 BELLOCODE_CONTAINER_TESTS=1 -- "${T[@]}" --filter "LiveEngine|LiveWorkspace|LiveContainerMCP|LiveContainerServices"
  if [[ $QUICK == 0 ]]; then
    run_area g2-kill-resync 1 BELLOCODE_G2=1 -- "${T[@]}" --filter "G2"
    run_area prompt-retry 2 BELLOCODE_PROMPT_ID=1 -- "${T[@]}" --filter "PromptRetryRealBinary"
    run_area orchestration-real 5 BELLOCODE_ORCH_REAL=1 -- "${T[@]}" --filter "OrchestrationRealBinary"
    run_area extras-real 7 BELLOCODE_EXTRAS_REAL=1 -- "${T[@]}" --filter "ExtrasRealBinary"
    run_area gitlab-real 3 BELLOCODE_GITLAB_REAL=1 -- "${T[@]}" --filter "GitLabRealBinary"
    run_area shell-e2e 2 BELLOCODE_SHELL_E2E=1 -- "${T[@]}" --filter "RealServer"
  else
    for area in g2-kill-resync prompt-retry orchestration-real extras-real gitlab-real shell-e2e; do skip_area "$area" "--quick"; done
  fi
fi

# 3. Plugin tests (bun in a container; bun never runs on the Mac).
run_area plugin-tests 0 -- swift run ContainerDemo plugin-test Plugin

# 4. The app with the candidate bundled, its smoke test (isolation self-check included) and the container e2e.
run_area app-bundle 0 BELLOCODE_APP_PATH="$APP" -- Scripts/make-app.sh debug
if grep -q $'^app-bundle\tPASS' "$RESULTS"; then
  run_area smoke 0 -- "$APP/Contents/MacOS/BelloCode" --smoke-test
  verdict="$(grep -E "isolation: (Isolated|Not verified|Problem):" "$OUT/logs/smoke.log" | tail -1 | sed -E 's/.*isolation: //' | cut -c1-160)"
  if grep -qE "isolation: Isolated:" "$OUT/logs/smoke.log"; then record "isolation-self-check" PASS 0 0 "$verdict"
  else record "isolation-self-check" FAIL 0 0 "${verdict:-no verdict in the smoke log}"; fi
  bundled="$(/usr/libexec/PlistBuddy -c 'Print :BelloCodeOpenCodeVersion' "$APP/Contents/Info.plist" 2> /dev/null)"
  [[ "$bundled" == "$VERSION" ]] && record "bundled-version" PASS 0 0 "Info.plist BelloCodeOpenCodeVersion $bundled" \
    || record "bundled-version" FAIL 0 0 "Info.plist says '$bundled'"
  if [[ $QUICK == 0 ]]; then
    run_area e2e-containers 2 BELLOCODE_SMOKE_E2E=1 -- "$APP/Contents/MacOS/BelloCode" --smoke-test
  else
    skip_area e2e-containers "--quick"
  fi
fi

# 5. Nothing left running from the candidate or the verify bundle.
left="$(pgrep -fl "Vendor/opencode/$VERSION/opencode|$APP/Contents" || true)"
[[ -z "$left" ]] && record "no-processes-left" PASS 0 0 "no opencode or app process from this run" \
  || record "no-processes-left" FAIL 0 0 "$(echo "$left" | wc -l | tr -d ' ') process(es) left"

python3 -I - "$RESULTS" "$OUT" "$VERSION" "$PIN" "$ROOT/Contracts/opencode-$VERSION/upgrade-diff.json" << 'EOF'
import json, os, sys
results, out, version, pin, diff_path = sys.argv[1:]
rows = [line.rstrip("\n").split("\t") for line in open(results) if line.strip()]
areas = [{"area": r[0], "status": r[1], "prompts": int(r[2]), "seconds": int(r[3]), "summary": r[4], "log": "logs/%s.log" % r[0]} for r in rows]
failed = [a for a in areas if a["status"] == "FAIL"]
prompts = sum(a["prompts"] for a in areas if a["status"] in ("PASS", "FAIL"))
diff = json.load(open(diff_path)) if os.path.exists(diff_path) else None
report = {"version": version, "pin": pin, "green": not failed, "prompts": prompts, "areas": areas,
          "impact": diff["impact"] if diff else []}
json.dump(report, open(os.path.join(out, "report.json"), "w"), indent=1)
lines = ["# opencode %s regression gate (pin %s)" % (version, pin), "",
         "**%s**: %d areas, %d failed, %d model prompts (zero-cost models only)." % (
             "ALL GREEN" if not failed else "FAILED", len(areas), len(failed), prompts), "",
         "| Area | Result | Prompts | Time | Summary |", "| --- | --- | --- | --- | --- |"]
for a in areas:
    lines.append("| %s | %s | %d | %ds | %s |" % (a["area"], a["status"], a["prompts"], a["seconds"], a["summary"].replace("|", "/")))
if diff:
    lines += ["", "## Contract changes that touch BelloCode (from %s)" % diff["from"], ""]
    for i in diff["impact"]:
        lines.append("- **%s** %s: %s%s" % (i["what"], i["change"], ", ".join(i["consumers"]), "; " + "; ".join(i["notes"]) if i.get("notes") else ""))
    if not diff["impact"]:
        lines.append("- none")
    lines += ["", "Full diff: Contracts/opencode-%s/UPGRADE-DIFF.md. Each change above is covered by the area that exercises its" % version,
              "consumer (decoders: unit-and-recorded-contract; HTTP shapes: mock-vs-real-contract; schedules/automations:",
              "isolation-self-check; permissions: permission-policy-real; browser: browser-bridge-attach)."]
open(os.path.join(out, "REPORT.md"), "w").write("\n".join(lines) + "\n")
print("opencode-verify: %s (%d failed); report %s/REPORT.md" % ("ALL GREEN" if not failed else "FAILED", len(failed), out))
sys.exit(1 if failed else 0)
EOF
