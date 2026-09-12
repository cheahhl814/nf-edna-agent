# nf-edna

[![Version](https://img.shields.io/badge/version-1.1.4-blue)](#-installation)
[![Type](https://img.shields.io/badge/type-agent%20skill-blueviolet)](#-installation)
[![Built with](https://img.shields.io/badge/built%20with-bioinfo--skill--creator-orange)](https://github.com/cheahhl814/bioinfo-skill-creator)

End-to-end agent orchestration of the nf-edna Nextflow DSL2 pipeline for environmental DNA (eDNA) metabarcoding analysis across four marker genes — 16S (Bacteria/Archaea), 18S-V9, COI, and 12S (Eukaryota). Drives intake → QC → denoise → classify → diversity → association stages with marker-specific presets, then turns outputs into a structured report. Mirrors the BettaMt ask-user-stop-points pattern and the canonical `bacterial-genome-analysis` evidence chain. Use when the user asks to "run an eDNA metabarcoding analysis", "process 16S/18S/COI/12S amplicon reads", "interpret eDNA results", or "set up an eDNA pipeline run". Builds on read-qc-trimming (raw-read QC upstream) and pairs with edna-gbif-publish (downstream GBIF Darwin Core publishing).

**Repository**: https://github.com/cheahhl814/nf-edna

> [!NOTE]
> Current version: **v1.1.4** (updated 2026-08-19).

## Contents

- [Installation](#-installation)
- [Usage](#-usage)
- [Pipeline overview](#-pipeline-overview)
- [Tools](#-tools)
- [Update check](#-update-check)
- [Repository layout](#-repository-layout)
- [Hard guarantees](#-hard-guarantees)
- [Nextflow runner](#-nextflow-runner)
- [Provenance](#-provenance)

## 🚀 Installation

This is an **agent skill**, not a user-facing library. The recommended install path is to let your AI agent import it.

**Option A — give your agent this prompt (recommended):**

```text
Install the nf-edna skill from
https://github.com/cheahhl814/nf-edna —
clone it into your agent's skills directory (the path your agent watches
for skills) and run `pixi install` from that directory. Then read the
skill's SKILL.md to understand its phases and the Input/Output contract
for each. Confirm when the environment is ready.
```

**Option B — manual install:**

```bash
git clone https://github.com/cheahhl814/nf-edna.git
cd nf-edna
pixi install
```

> [!TIP]
> `pixi install` resolves every pinned tool from `pixi.toml` (channels: conda-forge, bioconda) into an isolated `.pixi/` environment — no system-wide installs, no version conflicts with other skills.

## 💡 Usage

The skill is designed to be driven by an AI agent: the agent reads the master `SKILL.md`, detects the current phase from the filesystem state of your run directory, and routes to the right sub-skill.

### Natural-language prompts that trigger the skill

```text
run eDNA metabarcoding
process 16S amplicon reads
process 18S V9 reads
process COI reads
process 12S reads
```

### Manual phase execution

If you prefer to drive the phases yourself (or want to re-run a single phase):

```bash
# Set your run directory (all phase artifacts land here)
RUN_DIR=/path/to/run-dir

pixi run preflight   # Phase 1 — validate inputs, write preflight.md + params.json
pixi run run         # Phase 2 — execute the workflow (after preflight ≥ GO)
pixi run qc          # Phase 3 — build the final report (after run completes)
pixi run debug       # On failure — interpret stderr via the signature library
pixi run battle-test # Verify the skill's structural integrity
```

> [!IMPORTANT]
> Each phase has an explicit **Inputs/Outputs contract** at the top of its sub-skill `SKILL.md`. If the upstream artifact is missing (e.g. you run `run` before `preflight` passed), the sub-skill refuses to proceed and tells you which phase to run first. Phases are gated on purpose — don't skip them.

## 🔬 Pipeline overview

The analysis follows a phased evidence chain. Each phase consumes the artifacts of the previous phase and gates progression with a Go/No-Go check.

| # | Phase | Goal | Sub-skill | Artifact produced |
|:--|:------|:-----|:----------|:------------------|
| **1** | **Interpret** | **v1.1.0.** Adds the canonical BettaMt structure (§0 Inputs/Outputs contract, §0.5 Ask-User Stop Points with Evidence + | `interpret/` | `$RUN_DIR/interpret-artifact.md` |
| **2** | **Preflight** | **v1.1.0.** Adds the canonical BettaMt / `bettamt-preflight` structure (§0 Inputs/Outputs contract, §0.5 Ask-User Stop P | `preflight/` | `$RUN_DIR/preflight.md` |
| **3** | **Run** | **v1.1.0.** Adds the canonical BettaMt structure (§0 Inputs/Outputs contract, §0.5 Ask-User Stop Points with Evidence + | `run/` | `$RUN_DIR/run-summary.md` |
| **4** | **Runners** | This directory contains the **primary Nextflow DSL2 pipeline** of nf-edna. It is the engine that the bash recipes in `ru | `runners/` | `$RUN_DIR/runners-artifact.md` |

> [!TIP]
> Read each sub-skill's `SKILL.md` for the full procedure, its ask-user stop points, and its signature library (stderr pattern → cause → fix).

## 🧰 Tools

All tools are resolved from conda-forge/bioconda via the pinned `pixi.toml`.

| Tool | Version | Role |
|:-----|:--------|:-----|
| `python` | >=3.10 | Pinned conda dep |
| `julia` | >=1.10 | Pinned conda dep |
| `nextflow` | >=23.10.0 | Pinned conda dep |
| `pandas` | >=2.0 | Pinned conda dep |
| `pyyaml` | >=6.0 | Pinned conda dep |
| `jsonschema` | >=4.0 | Pinned conda dep |

Tool usage is grounded in the offline `docs-corpus/` snapshots (version-matched `--help`/`man` captures, upstream repo docs, and web docs as fallback) — the agent reads these instead of guessing flags.

## 🔄 Update check

Every skill built with [bioinfo-skill-creator](https://github.com/cheahhl814/bioinfo-skill-creator) ships a self-update check that compares the deployed git SHA against this upstream repo via `git fetch` — no GitHub API call, no extra dependencies.

```bash
pixi run update-check
```

| Verdict | Exit | Meaning |
|:--------|:-----|:--------|
| `UP-TO-DATE` | 0 | Local HEAD matches origin/HEAD |
| `LOCAL-AHEAD` | 0 | Unpushed local commits; no action needed |
| `BEHIND-BY-N` | 1 | Upstream is N commits ahead → re-pull/re-sync from this repo |
| `OFFLINE` | 2 | `git fetch` failed; informational only |
| `NO-ORIGIN` | 2 | No `origin` remote configured; informational only |

## 📁 Repository layout

```text
nf-edna/
├── SKILL.md                 # Master orchestrator (router — start here)
├── README.md                # This file
├── pixi.toml                # Pinned tool environment (pixi install)
├── docs-corpus/             # Offline snapshots of upstream tool docs
│   └── python/
│   └── julia/
│   └── nextflow/
│   └── pandas/
│   └── pyyaml/
│   └── jsonschema/
├── interpret/            # Phase sub-skill
├── preflight/            # Phase sub-skill
├── run/            # Phase sub-skill
├── runners/            # Phase sub-skill
├── bin/
│   └── skill-update-check.py  # Self-update check (pixi run update-check)
└── bin/
    └── scaffold-render.py     # Reproducibility — re-render the skill from params.json
```

## 🔒 Hard guarantees

- **Filesystem evidence chain** — every phase emits the artifact the next phase consumes; the boundary between phases is the filesystem, not agent memory.
- **Docs-grounded tool usage** — tool flags come from `docs-corpus/`, never from the agent's memory.
- **Explicit stop points** — ambiguous decisions are surfaced to you as *Evidence + Recommend + Options*, not auto-picked.
- **Reproducible environments** — every tool is pinned in `pixi.toml` and resolved via pixi.

## 🚀 Nextflow runner

For production / HPC / cohort runs, the skill ships a thin Nextflow DSL2 runner at `runners/nextflow-runner/` (nf-core-style resource labels, pinned containers, trace/report/timeline enabled).

```bash
# Stub smoke test (builds the DAG without executing)
nextflow run runners/nextflow-runner/main.nf -profile test -stub-run

# Real run
nextflow run runners/nextflow-runner/main.nf --input <samplesheet.csv> --outdir <outdir> -profile docker
```

The bash recipes remain the source of truth; the runner is a thin executor.

## Provenance

Built with the [bioinfo-skill-creator](https://github.com/cheahhl814/bioinfo-skill-creator) meta-skill (v1.1.0), following the AiX-BIO skill convention (preflight → build → debug → battle-test evidence chain). Pattern adopted from:

- **BettaMt-agents** — https://github.com/cheahhl814/BettaMt-agents
- **bacterial-genome-analysis** — https://github.com/cheahhl814/bacterial-genome-analysis
- **amr-gene-screening** — https://github.com/cheahhl814/amr-gene-screening

## License

Released under the MIT License — see the license file in this repository for details.