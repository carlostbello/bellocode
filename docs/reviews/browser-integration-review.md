# Shared Chromium for BelloCode

Design review, 18 November 2026. One supervised browser serves all projects and threads. The profile, site storage and sign-ins belong to the developer. A thread gets a named browse session in that browser. The built-in WebKit preview keeps its existing per-project storage. [Owner decisions](../PLAN.md#0-scope-constraints-from-the-owner-2026-11-16) · [WebKit contract](../features/browser.md)

## Baseline and scope

G7 exercised Debian arm64 Chromium 156, a policy-installed browse CRX, loopback relay, container-side MCP and TigerVNC Xvnc. One opencode agent filled a form, took a screenshot and read a public site. The prototype joined a fixture network directly. Production requires the project-routing proxy and concurrent session binding. [Spike and fixtures](../spikes/G7-chrome-browse-container.md) · [Container integration](../features/containers.md)

| G7 observation | Production consequence |
|---|---|
| 1,768,969,739-byte local image, including a 346,174,729-byte Node base | Check installed and transferred bytes separately when trimming the final stage. |
| Fresh idle 311 MiB, warm idle 374 MiB, browsing 789 MiB with 15 tabs, peak 914 MiB | Lazy start, one idle timer across all clients, explicit tab lifecycle. |
| Animated page used 56.7% of a core without a viewer and 58.6% with one. Rendering-only viewer used 19.8% separately | Disconnect hidden viewers. Measure the browser and the Mac viewer independently. |
| Headless Chromium noVNC client displayed keys in 27.6 ms p50 and clicks in 28.4 ms p50. WKWebView first paint 244–376 ms | Benchmark a visible WebKit pane before setting its latency budget. |
| Cookie absent on disk at +6 s, present at +41 s. Immediate TERM lost sign-in | Drain work and close Chromium gracefully. Test sign-in after stop and crash. |

Sources: [resource samples](../spikes/G7/resources.jsonl), [noVNC](../spikes/G7/liveview-novnc.txt), [WebKit](../spikes/G7/liveview-wkwebview.txt), [persistence](../spikes/G7/persistence.txt). This review has not run a fresh browser benchmark.
