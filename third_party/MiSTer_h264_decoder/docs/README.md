# Engineering design notes

**These are not user documentation.** They are the development record of the core: the
reasoning behind non-trivial design decisions, the measurements behind each choice, the
hardware bring-up histories, and the theories that turned out to be wrong.

📖 **The user manual's source is in `site/content/`** (published on release). If you are
trying to *use* the core, or to write a program that feeds it, read that. Nothing in this
directory is written for that purpose, and following a design note as though it were
instructions will mislead you.

## What this is for

These notes exist so that work can resume cold. They record *why*, not *what*: the code
says what it does; these say what else was tried, what the hardware measured, and which
assumptions turned out false. Entry points:

| File | Covers |
|---|---|
| `roadmap.md` | The phased plan, the open decisions and current status — the canonical "what's next" |
| `architecture.md` | Data flow, clock domains, memory ports, **the HPS interface (draft)**, the inherited `sys/` edits |
| `harvest.md` | What comes from MiSTer_UMD_Video (and MiSTer_DVD), in which phase; fixes exchanged since the fork |
| `hw_budget_and_lessons.md` | The fabric budget, and the verification rules a failed feature earned |
| `hil_harness.md` | Driving the real MiSTer from a session |
| `mgl_launch.md` | How an MGL launch works, and how an HPS program loads this core |
| `moonlight.md` | The Moonlight client (the proving ground): the decisions, the backend, the launcher, the gates |
| `p1_measurements.md` | Phase 1: what a stock Sunshine host sends, and the forked decoder's cycles per macroblock at 480p60 |
| `colour.md` | F2: the colour matrix and range (interface 0.16) -- the sources' tags, the decisions, the coefficients, the path |
| `spec_hardening.md` | Design to the format's maximum, not the test shelf; the known deviations |
| `conformance.md` | Feature-by-feature coverage matrix and the reference oracles |
| `references.md` | Specs, papers, oracles and repositories |
| `experiments.md` | Parking lot for undecided ideas |
| `history.md` | Condensed record of solved problems and every milestone fit |

Most of the process and several notes are inherited from **MiSTer_UMD_Video**, from which
this core was forked, and through it from **MiSTer_DVD**. Where a note cites a
measurement made there, it says so; those numbers are about that core's netlist, not
this one's.

This core was developed in a private repository before being published, and the public
history begins with an import of the accumulated work rather than the full commit-by-commit
trail. So:

- References written **`fj#NN`** (`PR fj#22`, `issue fj#20`) are **pre-publication** pull
  requests and issues, of this repository or of MiSTer_UMD_Video's. They have no equivalent
  on GitHub; they carry that prefix precisely so they can never be confused with the
  public repository's own `#NN`, which start from 1. MiSTer_DVD's are its public numbers,
  always named with it (`MiSTer_DVD PR #164`).
- **Commit SHAs quoted in these notes** refer to that earlier history and will not resolve
  in the public repository.

Neither affects the design rationale these notes exist to record.
