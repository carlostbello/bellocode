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

The fixes after 1.0.1 are summarised by area in [RELEASE-NOTES.md](../RELEASE-NOTES.md#unreleased-102).

## Open items

- **Suggestions not taken up:** A30, N34–N38 (above). None is a defect.
- **deep-review-1:** C9 (narrowed), D1 (worked around), attachment eviction grace, and the minor items and
  suggestions without a recorded disposition: S8, Q2–Q4, U2, U4, U5, D4, D5. No commit records a fix for them; treat them as
  open.
- **GF06 remainders:** `docs/snapshots/opencode-trusted-light.png` still renders the capture machine's per-user
  temporary folder (not identifying by itself; re-render with the snapshot harness to remove it), and
  `Scripts/opencode_contract.py` still writes recorded streams without normalising the sandbox path, so a future
  capture should be checked for personal paths before it is committed. The git history keeps the old strings.
- **GF08 remainder:** the moby/profiles notice is bundled and documented, but Settings ▸ Acknowledgements does not list
  it yet.
- **Owner decisions (GLM OD1–OD4):** no licence has been chosen; the history's author identity; whether to publish these
  review and threat-model documents; the default branch and an explicit push refspec (GF04, GF05, GF07).
