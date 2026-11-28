# Reviews

Independent reviews of BelloCode, in the order they were made, and what happened to their findings. Each report is
kept as written; file and line references point at the revision it reviewed, not at today's tree. Several reports
describe, step by step, how a boundary could have been crossed at that revision; every such finding listed below was
fixed before the next release unless this index says otherwise.

| Report | Date | Revision | Findings | Disposition |
| --- | --- | --- | --- | --- |
| [M1-review.md](M1-review.md) | 2026-11-16 | `develop` after M1 | M1–M10, m1–m3 | Fixed (disposition in the report; m3 for the cited sleeps), except M6, deferred because the transcript was being replaced by TranscriptKit; the new transcript was reviewed in M2–M4 |
| [M2-M4-review.md](M2-M4-review.md) | 2026-11-16 | `develop` after M2–M4 | 0 critical, 9 major, 3 minor | Fixed (disposition table in the report) |
| [M3-M6-review.md](M3-M6-review.md) | 2026-11-17 | `develop` after M6-A | 3 critical, 6 major, 1 minor | All fixed in M6-B; none deferred (disposition table in the report) |
| [deep-review-1.md](deep-review-1.md) | 2026-11-18 | `6db276a` | Correctness C1–C10, security S1–S8, quality Q1–Q4, UX U1–U5, dependencies D1–D5 | C1–C10, S1–S7, U1, U3, Q1, D2 and D3 fixed (two disposition sections in the report), with these left open: C9 is narrowed, not closed (opencode offers no version precondition for metadata writes); D1, SwiftTerm's build plugin stalling under Command Line Tools, is worked around by the `SWIFTTERM_BUILD_*` values in the Makefile and `make-app.sh`; the attachment store's in-session eviction still relies on a one-hour grace. The remaining minor items and suggestions (S8, Q2–Q4, U2, U4, U5, D4, D5) have no recorded disposition |
| [browser-integration-review.md](browser-integration-review.md) | 2026-11-18 | design review | Design for the shared Chromium | Adopted as the design of the [shared browser](../features/shared-browser.md); not a list of defects |
| [release-1.0-review.md](release-1.0-review.md) | 2026-11-18 | `59fd67c` | R01–R35: 4 critical, 27 major, 4 minor | Fixed before 1.0.0 (release fixes A, B and C). The 1.0.0 Neon review re-verified each one; those it found incomplete were reported again as N findings and fixed in 1.0.1 |
| [v1.0.0-astra-review.md](v1.0.0-astra-review.md) | 2026-11-20 | `v1.0.0` (`71238ec`) | A01–A30: 5 critical, 18 major, 6 minor, 1 suggestion | A01–A29 fixed in 1.0.1 (P1–P4). A30, a suggestion to retire a parallel parser, was not taken up |
| [v1.0.0-neon-review.md](v1.0.0-neon-review.md) | 2026-11-20 | `v1.0.0` (`71238ec`) | N01–N38: 6 critical, 16 major, 11 minor, 5 suggestions | N01–N33 fixed in 1.0.1 (P1–P4). N34–N38 are refactoring and performance suggestions (shared parsers, splitting large files, store write amplification, a transcript fast path, one process runner) and remain open as post-1.0 work |
| [v1.0.1-astra-final-check.md](v1.0.1-astra-final-check.md) | 2026-11-23 | `v1.0.1` (`ab25a8e`) | AF01–AF27: 8 blocker, 18 major, 1 minor | All fixed after 1.0.1 (P5, P6, P6b, P7, P8, P9) |
| [v1.0.1-neon-final-check.md](v1.0.1-neon-final-check.md) | 2026-11-23 | `v1.0.1` (`ab25a8e`) | NF01–NF24: 2 blocker, 12 major, 10 minor | All fixed after 1.0.1 (P6, P7, P8, P9). Its closing list of test-coverage blind spots is advice, partly addressed by the NF13–NF15 test fixes |
| [v1.0.1-glm-final-check.md](v1.0.1-glm-final-check.md) | 2026-11-23 | `v1.0.1` (`ab25a8e`) | GF01–GF14: 3 major, 11 minor; 4 owner decisions | Code: GF02, GF14 (P8) and GF11–GF13 (P9) fixed. Documentation: GF01, GF03, GF06, GF08, GF09 and GF10 fixed in the documentation pass, with the remainders below. GF04, GF05 and GF07 and OD1–OD4 are publishing decisions for the owner, not defects in the tree |
| [v1.0.1-astra-verification.md](v1.0.1-astra-verification.md) | 2026-11-23 | `8e02aca` | Status of AF01–AF27; AV01–AV14 | Hold. Open items and AV01–AV14 fixed in Q1–Q5 |
| [v1.0.1-neon-verification.md](v1.0.1-neon-verification.md) | 2026-11-23 | `8e02aca` | Status of NF01–NF24; NV01–NV16 | Fixed in Q1–Q5 |
| [v1.0.1-glm-verification.md](v1.0.1-glm-verification.md) | 2026-11-23 | `8e02aca` | Status of GF11–GF14; GV01–GV10 | No blocker. GV findings fixed in Q1–Q5; GV10 closed in R3b |
| [v1.0.1-astra-verification-2.md](v1.0.1-astra-verification-2.md) | 2026-11-23 | `6c42b0e` | 11 incomplete; AV2-01–AV2-05 | Hold. Fixed in R3a–R3c; AF08 finished in R4a (one path-swap race accepted), AV2-02 in R4b–R6 |
| [v1.0.1-neon-verification-2.md](v1.0.1-neon-verification-2.md) | 2026-11-23 | `6c42b0e` | NV2-01, NV2-02 (major) | Fixed in R3a–R3c |
| [v1.0.1-glm-verification-2.md](v1.0.1-glm-verification-2.md) | 2026-11-23 | `6c42b0e` | GW01, GW02 (blocker); GV10 status | Fixed in R3a and R3b; the last GW02 spellings (`--text`, `--filter`) in `95268f0` |
| [v1.0.1-astra-round3-check.md](v1.0.1-astra-round3-check.md) | 2026-11-23 | `5c9ed06` | AF08, GW02, AV2-02 open; R3-01 (new) | Hold. AF08 fixed in R4a (one path-swap race accepted), GW02 in `95268f0`, R3-01 in R4b, AV2-02 in R4b–R6 |
| [v1.0.1-neon-round3-check.md](v1.0.1-neon-round3-check.md) | 2026-11-23 | `5c9ed06` | NV2-01, NV2-02 closed | Push |
| [v1.0.1-glm-round3-check.md](v1.0.1-glm-round3-check.md) | 2026-11-24 | `e6b84a6` | GW01, GW02, GV10 closed; GR3-01 (blocker) | Hold. GR3-01 fixed in `eebf7b9`; R3-01 confirmed closed at `705d749` |
| [v1.0.2-astra-final-verification.md](v1.0.2-astra-final-verification.md) | 2026-11-24 | `dd34d1e` | AF08, AV2-02, GR3-01 open; R4-01 (new); documentation | Hold. GR3-01 (`xxd`) and the documentation fixed in `013a161`; R4-01 in R5 (`d3f5f2a`); AV2-02 finished in R6; the AF08 path-swap race accepted (below) |
| [v1.0.2-astra-reverification.md](v1.0.2-astra-reverification.md) | 2026-11-24 | `7f2102b` | R4-01, GR3-01 closed; AV2-02 open; R5-01, R5-02 (new); documentation | Hold. Fixed in R6 (`4b7e5a4`): a composer takes no edits until it has observed its loaded draft, which removes R5's pre-load hand-over. The guide's repository-instruction paragraph was corrected |
| [v1.0.2-glm-final-verification.md](v1.0.2-glm-final-verification.md) | 2026-11-24 | `1dc68ff` | GR3-01 closed; publication scan of the history; R6-01 confirmed | Hold on R6-01 only. R6-01 fixed (below); the BSD `uniq` residual fixed; the snapshot count corrected |
| [v1.0.2-astra-r6-check.md](v1.0.2-astra-r6-check.md) | 2026-11-24 | `1dc68ff` | AV2-02, R5-01, R5-02 closed; R6-01 (new); documentation | Hold. R6-01 fixed: a refused review comment keeps its editor and text, and marks no line. The feature note's Retry, Edit in Composer and first-send statements qualified; two first-send cases listed below |
| [v1.0.2-neon-final-verification.md](v1.0.2-neon-final-verification.md) | 2026-11-24 | `60499dc` | Full-app flows and public docs; NV3-01 (crash) | Hold on NV3-01 only. Fixed: a new-thread draft whose window closed while its first send was creating the thread no longer traps. Astra confirmed R6-01 closed at `60499dc` with no new blocker (in its reply; no report was filed). GLM then confirmed R6-01, NV3-01 and the BSD `uniq` fix closed at the `v1.0.2` tag (`3f2cb19`), with nothing in the new commits to remove from the public history (also in its reply) |

The fixes after 1.0.1 are summarised by area in [RELEASE-NOTES.md](../RELEASE-NOTES.md#102-2026-11-24).

## Open items

- **Suggestions not taken up:** A30, N34–N38 (above). None is a defect.
- **deep-review-1:** C9 (narrowed), D1 (worked around), attachment eviction grace, and the minor items and
  suggestions without a recorded disposition: S8, Q2–Q4, U2, U4, U5, D4, D5. No commit records a fix for them; treat them as
  open.
- **GF06 remainders:** the six `docs/snapshots/opencode-{problems,trusted,untrusted}-{dark,light}.png` snapshots still
  render the capture machine's per-user temporary folder (not identifying by itself; re-render with the snapshot harness to remove it), and
  `Scripts/opencode_contract.py` still writes recorded streams without normalising the sandbox path, so a future
  capture should be checked for personal paths before it is committed. The git history keeps the old strings.
- **GF08 remainder:** the moby/profiles notice is bundled and documented, but Settings ▸ Acknowledgements does not list
  it yet.
- **Known limitations accepted for 1.0.2:**
  - Auto's shell analysis is best effort, not a boundary. A program run by its path (`bin/cat`) is classified by its
    name. ripgrep's `--pre` can come from `RIPGREP_CONFIG_PATH`, but every way to set that variable on a line goes to
    the reviewer (GLM round 3).
  - Repository instructions are withheld when a session's folder crosses a link inside a checkout (AF08). The pin
    check and the read of `AGENTS.md` are separate path lookups, so a process that swaps directories inside your
    checkout at that exact moment could have another checkout's instructions read (Astra, 1.0.2 final verification).
    It needs local write access to your files, which already allows editing `AGENTS.md` directly. Accepted, not fixed.
  - An unreadable pin watermark makes every unpinned session count as old: it is pinned only when its path holds no
    link, and after an eviction such a path can be pinned to a different folder at the same address.
  - Approved pushes need git 2.46 or Apple Git-155 or later; an older git is refused (AF06, GV10).
  - The live tests that drive a real model were not re-run for 1.0.2, because the free opencode model's quota was
    exhausted. Everything that uses the mock provider passed.
  - A rewound prompt that is still waiting for a slow draft is lost if the app quits first, and the new-thread draft
    (before its thread exists) has no shared revision across windows (R4b follow-ups). While a thread's draft is
    loading (normally milliseconds) its composer is read-only; after 5 seconds it offers Retry and saves nothing (R6).
  - Two narrow first-send cases remain (Astra, R6 check): a failed first send whose new thread's draft has not loaded
    within ten minutes is not restored to the composer, and a follow-up typed in the new-thread editor just as the
    thread is created can miss its debounced save.
  - A GitLab merge-request review comment closes its editor before its asynchronous draft save finishes; if that save
    fails the error is shown but the text is not put back. An image pasted as TIFF and converted just as you switch
    threads can attach to the newly shown thread (Astra and Neon, 1.0.2).
  - When a window closes while a new thread's first send is still creating it (NV3-01), that thread's model stays open
    until the app quits, and the project's new-thread draft may still show the sent prompt after a relaunch (a
    duplicate, not a loss). A click outside an open review-comment editor still closes it and drops its text (GLM, 1.0.2).
  - On the Mac's own BSD `uniq`, `uniq in.txt -out` writes `-out`; Auto now counts it as a write too (GLM 1.0.2 final
    verification). Commands normally run in Linux containers, where GNU `uniq` does not.
- **Owner decisions (GLM OD1–OD4):** no licence has been chosen; the history's author identity; whether to publish these
  review and threat-model documents; the default branch and an explicit push refspec (GF04, GF05, GF07).
