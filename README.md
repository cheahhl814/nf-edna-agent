# edna-agent

[![Version](https://img.shields.io/badge/version-1.2.0-blue)](#-installation)
[![Type](https://img.shields.io/badge/type-agent%20skill-blueviolet)](#-installation)
[![Built with](https://img.shields.io/badge/built%20with-bioinfo--skill--creator-orange)](https://github.com/cheahhl814/bioinfo-skill-creator)

Agent-driven orchestration of environmental DNA (eDNA) metabarcoding analysis for four marker genes — **16S** (Bacteria/Archaea), **18S-V9**, **COI**, and **12S** (Eukaryota). Covers intake → QC (primer trimming) → denoise (pair merge + ASV inference + decontamination + negative-control filtering) → classify (DECIPHER IDTAXA + confidence filter + agglomeration) → diversity (tree, alpha, beta/PERMANOVA, community typing) → association (differential abundance, correlations) → interpret (structured report + narrative). As of **v1.2.0 there is no workflow engine**: the agent executes each stage's tools directly under per-stage **pixi** environments, following the canonical recipe tables in `run/edna-run/SKILL.md` — validated on two real-data battle-test rounds (2026-08-19, 2026-10-07).

**Repository**: https://github.com/cheahhl814/nf-edna-agent

> [!NOTE]
> Current version: **v1.2.0** (updated 2026-10-08). Renamed from **edna-agent** (the `nf-` prefix marked the removed Nextflow era; see the mirror case `nf-phylogenetics-agent → phylogenetics-agent`).

## Contents

- [Installation](#-installation)
- [Usage](#-usage)
- [Pipeline overview](#-pipeline-overview)
- [Tools](#-tools)
- [Update check](#-update-check)
- [Repository layout](#-repository-layout)
- [Hard guarantees](#-hard-guarantees)
- [Provenance](#provenance)

## 🚀 Installation

This is an **agent skill**, not a user-facing library. The recommended install path is to let your AI agent import it.

**Option A — give your agent this prompt (recommended):**

```text
Install the edna-agent skill from
https://github.com/cheahhl814/nf-edna-agent —
clone it into your agent's skills directory (the path your agent watches
for skills) and confirm it is on PATH. Then read the skill's SKILL.md to
understand its phases and the Input/Output contract for each. Confirm
when ready.
```

**Option B — manual install:**

```bash
git clone https://github.com/cheahhl814/nf-edna-agent.git
cd nf-edna-agent
pixi install          # agent runtime env; per-stage tool envs resolve lazily on first use
```

> [!TIP]
> Per-stage tool environments (`env/{stage}/pixi.toml`) resolve automatically the first time a stage runs — no system-wide installs, no version conflicts.

## 💡 Usage

The skill is designed to be driven by an AI agent: the agent reads the master `SKILL.md`, detects the current phase from the filesystem state of your run directory, and routes to the right sub-skill.

### Natural-language prompts that trigger the skill

```text
run eDNA metabarcoding
process 16S amplicon reads
process 18S V9 reads
process COI reads
process 12S reads
interpret eDNA results
```

### Manual stage execution

If you prefer to drive the stages yourself (or want to re-run a single stage):

```bash
# All run artifacts land under <dataset-dir>/results/<run_id>/
pixi run intake      # info → Phase 1 preflight/edna-intake
pixi run run-stage   # info → Phase 2 run/edna-run (stage ladder + recipe tables)
pixi run interpret   # info → Phase 3 interpret/edna-interpret
pixi run summarise --run_id <run_id>   # (after association) build run_summary.json
pixi run test        # structural smoke tests
```

> [!IMPORTANT]
> Each phase has an explicit **Inputs/Outputs contract** at the top of its sub-skill `SKILL.md`. The `pipeline_state.json` verdict gate (GO / GO-WITH-WARNINGS / NO-GO) is enforced before any execution. Phases are gated on purpose — don't skip them.

## 🔬 Pipeline overview

The analysis follows a phased evidence chain. Each phase consumes the artifacts of the previous phase and gates progression with verdict checks.

| # | Phase | Goal | Sub-skill | Artifact produced |
|:--|:------|:-----|:----------|:------------------|
| **1** | **Intake** | Gather parameters (marker, primers, metadata, IDTAXA model), validate inputs (7 evidence items E1–E7), write the verdict-gated machine contract | `preflight/edna-intake/` | `results/<run_id>/pipeline_state.json` + single merged `params.json` |
| **2** | **Run** | Execute stages agent-driven from the recipe tables (qc → denoise → classify → diversity → association), verifying outputs before updating state | `run/edna-run/` | per-stage outputs under `results/<run_id>/` + updated state |
| **3** | **Interpret** | Turn `run_summary.json` into a structured report + narrative, then Q&A | `interpret/edna-interpret/` | `<run_id>-report.md` + `narrative.md` |

Auxiliary sub-skills (independent, chainable):

| Sub-skill | Purpose |
|:----------|:--------|
| `idtaxa-training/` | Train a DECIPHER IDTAXA classifier from a reference FASTA (NCBI headers → DECIPHER headers → trained `.rds`) |
| `reference-db/` | Curated download URLs for the 4 marker reference databases + validation + training chain |
| `edna-visualize/` | Publication-ready figures from the rank count tables |

> [!TIP]
> Read each sub-skill's `SKILL.md` for the full procedure, its ask-user stop points, and its signature library (stderr pattern → cause → fix).

## 🧰 Tools

All tools are resolved from conda-forge/bioconda via the pinned pixi manifests.

| Stage env | Tools |
|:----------|:------|
| agent runtime (`pixi.toml`) | python ≥3.10, julia ≥1.10, pandas, pyyaml, jsonschema |
| `env/qc/` | cutadapt 5.x, fastqc |
| `env/denoise/` | NGmerge 0.5, vsearch 2.3x, biom-format, R (argparse, data.table) |
| `env/decontam/` | julia 1.12 (ArgParse, CSV, DataFrames, FASTX, HypothesisTests), auto-instantiate task |
| `env/classification/` | R 4.5 + Bioconductor (DECIPHER, TreeSummarizedExperiment, mia 1.18 + rbiom 2.2.1 pin, mia), seqtk |
| `env/diversity/` | R 4.5 (ape, scater, mia/rbiom 2.2.1, ggplot2), mafft, FastTree |
| `env/association/` | R 4.5 (Maaslin2, data.table, ggplot2, rbiom 2.2.1 pin) |
| `env/database/`, `env/geocuration/` | reference/geocuration helpers (rentrez, xml2, etc.) |

Tool usage is grounded in each sub-skill's signature library and the battle-test evidence (two full real-data runs) — the agent reads the documented recipes instead of guessing flags.

## 🔄 Update check

Every skill built with [bioinfo-skill-creator](https://github.com/cheahhl814/bioinfo-skill-creator) ships a self-update check that compares the deployed git SHA against this upstream repo via `git fetch` — no GitHub API call, no extra dependencies.

```bash
pixi run update-check        # or: python3 bin/skill-update-check.py
```

| Verdict | Exit | Meaning |
|:--------|:-----|:--------|
| `UP-TO-DATE` | 0 | Local HEAD matches origin/HEAD |
| `LOCAL-AHEAD` | 0 | Unpushed local commits; no action needed |
| `BEHIND-BY-N` | 1 | Upstream is N commits ahead → re-sync from this repo |
| `OFFLINE` | 2 | `git fetch` failed; informational only |
| `NO-ORIGIN` | 2 | No `origin` remote configured; informational only |

## 📁 Repository layout

```text
edna-agent/
├── SKILL.md                 # Master orchestrator (router — start here)
├── README.md                # This file
├── pixi.toml                # Agent runtime env (pixi install)
├── params.json              # Render input (skill inventory)
├── params/                  # Marker presets: 16s / 18s-v9 / coi / 12s
├── env/                     # Per-stage tool environments (qc, denoise, decontam, classification, diversity, association, database, geocuration)
├── bin/                     # Stage + auxiliary scripts (R/Julia/Python), incl. skill-update-check.py, summarise_run.py
├── preflight/edna-intake/   # Phase 1 sub-skill (SP1–SP7, E1–E7 verdict gate)
├── run/edna-run/            # Phase 2 sub-skill (stage ladder + agent-driven recipe tables)
├── interpret/edna-interpret/ # Phase 3 sub-skill (report + narrative + Q&A)
├── idtaxa-training/         # Auxiliary sub-skill (train IDTAXA classifiers)
├── reference-db/            # Auxiliary sub-skill (marker reference databases)
├── edna-visualize/          # Auxiliary sub-skill (publication figures)
└── test_smoke.py            # Structural smoke tests (pixi run test)
```

## 🔒 Hard guarantees

- **Filesystem evidence chain** — every phase emits the artifact the next phase consumes; the boundary between phases is the filesystem, not agent memory.
- **Verdict-gated execution** — `pipeline_state.json.verdict` must be ≥ `GO-WITH-WARNINGS` before any stage runs; state is updated only after verified outputs.
- **Recipes are measured, not guessed** — every command in the recipe tables was executed on real data in a battle-test round; failures root-caused and encoded in signature libraries.
- **Explicit stop points** — ambiguous decisions are surfaced as *Evidence + Recommend + Options*, not auto-picked.
- **Per-stage env isolation** — tools resolve under `env/{stage}/`, never imported into the agent runtime.
- **Marker assumptions are checked, not trusted** — primer-signature detection alone can be a false GO (battle-test round 2, F10): run the post-denoise ASV-vs-reference sanity check before CLASSIFY.

## Provenance

Built with the [bioinfo-skill-creator](https://github.com/cheahhl814/bioinfo-skill-creator) meta-skill, following the AiX-BIO skill convention (preflight → build → debug → battle-test evidence chain). Pattern adopted from:

- **BettaMt-agents** — https://github.com/cheahhl814/BettaMt-agents
- **bacterial-genome-analysis** — https://github.com/cheahhl814/bacterial-genome-analysis
- **amr-gene-screening** — https://github.com/cheahhl814/amr-gene-screening

Real-data battle-test rounds: 2026-08-19 (v1.1.0–v1.1.1 era), 2026-10-07/08 (v1.1.5 → v1.2.0; verdicts in the corresponding reports / wiki).