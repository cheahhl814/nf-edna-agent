# nf-edna

> **v1.0.0.** Initial scaffold conforming to the BettaMt / AiX-BIO bioinformatics skill format. The Nextflow DSL2 pipeline (main.nf, modules/, bin/, params/, env/) was flattened from a nested `nf-edna/` directory to the skill root. Three Claude-Code-style phase skills were migrated from `.claude/skills/` into the canonical sub-skill layout (`preflight/edna-intake`, `run/edna-run`, `interpret/edna-interpret`). A root `SKILL.md` router + root `pixi.toml` (agent runtime) were added; per-stage pixi environments under `env/` are preserved unchanged (Nextflow-internal). Pipeline files, marker presets, and Pixi envs are all functional as in v0.x; only the agent-skill wrapping changed.

An agent-orchestrated Nextflow DSL2 pipeline for environmental DNA (eDNA) metabarcoding analysis, covering **QC → denoise → classify → diversity → association** for four marker genes: **16S** (Bacteria/Archaea), **18S-V9**, **COI**, and **12S** (Eukaryota). Marker-specific behavior (amplicon length range, kingdom filter, taxonomic ranks, optional geographic curation) is supplied via `-params-file` presets rather than separate pipeline copies.

## Dual-Audience Design

This meta-skill serves both **AI coding agents** and **human eDNA scientists**. The structured triggers, stage-detection ladder, and handoff-contract artifacts guide autonomous execution; the embedded **Stages**, **Marker presets**, and **Composability** sections provide human readers with the intuition to plan a run.

## Pipeline Stages

| # | Stage | Module | What it does | Sub-skill (agent orchestration) |
|:---|:---|:---|:---|:---|
| 0 | **Intake** | — | Gather run parameters, validate inputs, write `pipeline_state.json` | `preflight/edna-intake` |
| 1 | **QC** | `modules/qc.nf` | Primer trimming (cutadapt), FastQC | `run/edna-run` |
| 2 | **Denoise** | `modules/denoise.nf` | Pair merging (NGmerge), ASV inference (VSEARCH UNOISE3), decontamination | `run/edna-run` |
| 3 | **Classify** | `modules/classify.nf` | IDTAXA classification, confidence filtering, rank agglomeration, optional geocuration | `run/edna-run` |
| 4 | **Diversity** | `modules/diversity.nf` | Phylogenetic tree, alpha diversity, beta diversity (PERMANOVA, community typing) | `run/edna-run` |
| 5 | **Association** | `modules/association.nf` | Differential abundance, taxon-environment and taxon-taxon correlation | `run/edna-run` |
| 6 | **Interpret** | — | Turn `run_summary.json` into structured report + narrative Results-section draft + interactive Q&A | `interpret/edna-interpret` |

Each pipeline stage can be run incrementally via named Nextflow entry points (`QC_ONLY`, `DENOISE_ONLY`, `CLASSIFY_ONLY`, `DIVERSITY_ONLY`, or the default workflow for all stages including association), with `-resume` reusing cached work from prior stages.

## Repository layout

```
nf-edna/
├── SKILL.md                          ← agent-skill router (v1.0.0)
├── README.md                         ← this file
├── pixi.toml                         ← agent runtime env (nextflow, python, julia, …)
├── main.nf                           ← Nextflow DSL2 entry point
├── nextflow.config                   ← pipeline config
├── modules/
│   ├── qc.nf
│   ├── denoise.nf
│   ├── classify.nf
│   ├── diversity.nf
│   └── association.nf
├── bin/                              ← 21 R / Julia / Python helper scripts
├── params/                           ← marker presets
│   ├── 16s.json
│   ├── 18s-v9.json
│   ├── coi.json
│   └── 12s.json
├── env/                              ← per-stage Pixi environments (Nextflow-internal)
│   ├── qc/pixi.toml                  ← cutadapt, fastqc
│   ├── denoise/pixi.toml             ← NGmerge, VSEARCH
│   ├── classification/pixi.toml      ← IDTAXA (R/Bioconductor)
│   ├── database/pixi.toml            ← reference DB preparation
│   ├── diversity/pixi.toml           ← phyloseq, vegan (R)
│   ├── geocuration/pixi.toml         ← geocoding helper env
│   └── association/pixi.toml         ← differential abundance
├── preflight/
│   └── edna-intake/SKILL.md          ← intake sub-skill (writes pipeline_state.json)
├── run/
│   └── edna-run/SKILL.md             ← execution sub-skill (invokes nextflow run)
├── interpret/
│   └── edna-interpret/SKILL.md       ← interpretation sub-skill (writes report.md)
├── test_smoke.py                     ← 23 structural smoke tests
└── battle-test-report.md             ← PASS-WITH-WARNINGS verdict (v1.0.0)
```

## Prerequisites

- [Nextflow](https://www.nextflow.io/) ≥ 23.10.0 (DSL2-compatible release). Install via `curl -s https://get.nextflow.io | bash`.
- [Pixi](https://pixi.sh/) — manages the per-stage tool environments under `env/` (cutadapt, NGmerge, VSEARCH, R/Bioconductor, Julia). Each Nextflow process invokes its tools via `pixi run --manifest-path env/{stage}/pixi.toml ...`; Pixi resolves and caches these environments on first use — no manual `conda`/`mamba` setup required. The agent runtime at the skill root uses the top-level `pixi.toml`.
- Reference assets per marker (trained IDTAXA models, taxonomy tables) — live under `assets/{16s,18s-v9,coi,12s}/` and are gitignored; supply your own per `.gitignore`'s tracked patterns.

## Running the pipeline directly (bypassing the agent)

```bash
# From the skill root
nextflow run main.nf \
  -params-file params/16s.json \
  -params-file path/to/run-specific-params.json \
  -resume
```

`-params-file` flags merge left-to-right (last wins) — always pass the marker preset **first**, then the run-specific overrides (manifest, metadata, IDTAXA model, run ID, etc.) **second**.

To run only through a given stage:

```bash
nextflow run main.nf -entry CLASSIFY_ONLY -params-file ... -params-file ...
```

## Marker presets (`params/`)

| Preset        | Marker | Length range | Kingdoms          | DAA/correlation level | Geocurate |
| ------------- | ------ | ------------ | ----------------- | --------------------- | --------- |
| `16s.json`    | 16S    | 350–550 bp   | Bacteria, Archaea | Genus                 | off       |
| `18s-v9.json` | 18S-V9 | 100–180 bp   | Eukaryota         | Species               | off       |
| `coi.json`    | COI    | 290–340 bp   | Eukaryota         | Species               | on        |
| `12s.json`    | 12S    | 150–200 bp   | Eukaryota         | Species               | on        |

## Running the agent (canonical flow)

The agent-skill wrapping does **not** change what runs — only how it's invoked. With the skill deployed to `~/.pi/agent/skills/nf-edna/`, an AI agent will auto-load the orchestrator (`SKILL.md`) when the user asks anything matching its `triggers:` frontmatter (e.g. "run an eDNA metabarcoding analysis", "process 16S amplicon reads").

The orchestrator detects the user's stage from filesystem evidence and routes to the right sub-skill:

| Detected stage | Sub-skill invoked | Artifact produced |
| --- | --- | --- |
| no `pipeline_state.json` yet | `preflight/edna-intake` | `results/{run_id}/pipeline_state.json` |
| state exists, stages pending | `run/edna-run` | updated `pipeline_state.json` + stage outputs |
| ≥ classify complete | `interpret/edna-interpret` | `results/{run_id}/<run_id>-report.md` + `narrative.md` |

### Example agent prompts

**Starting a new run:**

> "I have a new 16S run, sample data in `raw_reads/siteA/`, metadata at `metadata/siteA.tsv`. Primers are the standard 515F/806R pair. Help me set it up."

**Continuing an in-progress run:**

> "Continue run `16s-20260819-siteA` — run all remaining stages."

**Running only through a specific stage:**

> "For run `12s-20260901-reef3`, just run through classification — I want to check taxonomy before committing to diversity/association."

**Retrying after a failure:**

> "The QC stage failed on run `coi-20260903-bay2` — primer not found. Retry with `--primer_mismatch_rate 0.2`."

**Interpreting completed results:**

> "Interpret run `16s-20260819-siteA` and write the report."

**Follow-up Q&A after a report is written:**

> "Which taxa are driving the separation between the site clusters?"
> "Is the low read count in sample siteA-03 something I should worry about?"
> "Summarize this for a manuscript Results section, focused on the dominant phyla."

## Post-processing for AI interpretation

`bin/summarise_run.py` consolidates a completed run's outputs (read flow, ASV counts, taxonomy, top taxa, alpha/beta diversity, differential abundance, correlations, blank QC warnings) into a single compact `run_summary.json`, avoiding the need to load large raw tables into an LLM's context window:

```bash
python3 bin/summarise_run.py \
  --results_dir results \
  --run_id {run_id}
```

## Composability with other AiX-BIO skills

| Skill | When to chain |
| --- | --- |
| [`read-qc-trimming`](https://github.com/cheahhl814/read-qc-trimming) | Run **before** `preflight/edna-intake` if your reads are raw (untrimmed). nf-edna's `qc` stage does primer trimming; if your reads also need adapter trimming + quality filtering, do that first. |
| [`pixi-env-mgmt`](https://github.com/cheahhl814/pixi-env-mgmt) | Use to add/modify the per-stage pixi envs under `env/`. |
| [`nextflow-pipelines`](https://github.com/cheahhl814/nextflow-pipelines) | Reference for the DSL2 idioms used in `modules/` and `main.nf`. |
| [`edna-gbif-publish`](https://github.com/cheahhl814/edna-gbif-publish) | After `interpret/edna-interpret`, publish occurrence data to GBIF. |
| [`geocoding`](https://github.com/cheahhl814/geocoding) | Used internally by `bin/geocurate_fetch.R` if you enable geocuration for a run. |
| [`bioinfo-skill-creator`](https://github.com/cheahhl814/bioinfo-skill-creator) | Meta-skill whose `battle-test` pattern the `test_smoke.py` here mirrors. |

## v1.0.0 — what changed

| Change | v0.x (pre-restructure) | v1.0.0 (BettaMt) |
| --- | --- | --- |
| **Repository layout** | Pipeline nested under `nf-edna/` subdirectory | Flattened — `main.nf`, `modules/`, `bin/`, `params/`, `env/` at skill root |
| **Agent skill wrapping** | Three Claude-Code-style skills under `.claude/skills/*.md` (slash-command-only, wrong location for Pi) | Canonical BettaMt sub-skill layout: `preflight/edna-intake/`, `run/edna-run/`, `interpret/edna-interpret/` + root `SKILL.md` router |
| **Frontmatter** | Bare `name:` / `description:` (Claude Code shape) | Full `name:` / `description:` / `version: 1.0.0` / `updated: "2026-08-19"` / `triggers:` (AiX-BIO shape) on all 4 SKILL.md files |
| **Pixi environment** | Single env at `nf-edna/env/pixi.toml` only | Root `pixi.toml` (agent runtime: nextflow, python, julia, pandas, pyyaml, jsonschema) + per-stage envs under `env/{stage}/pixi.toml` preserved |
| **Discovery** | Not listed in `skills/INDEX.md` | Row #18b in Genomics & Bioinformatics table + discovery-heuristic entry |
| **Battle tests** | None | `test_smoke.py` (23 structural smoke tests) + `battle-test-report.md` (PASS-WITH-WARNINGS) |
| **Git hygiene** | `.gitignore` covered `nf-edna/assets/**` (stale, pre-flatten) | Updated to `assets/**` + new coverage for `results/`, `work/`, `.nextflow.log*`, `*.fq.gz` |

## What changed in the agent-skill wrapping (and what didn't)

**Pipeline behavior is unchanged.** All 21 R/Julia/Python scripts in `bin/`, all 5 module files, the 4 marker presets, and all 7 per-stage pixi envs are byte-identical to the previous version. Only the agent orchestration was restructured:

- `preflight/edna-intake` body was migrated verbatim from `.claude/skills/edna-intake.md`; only the frontmatter was updated (kebab-case name + version/updated/triggers).
- `run/edna-run` body migrated verbatim from `.claude/skills/edna-run.md`; frontmatter updated.
- `interpret/edna-interpret` body migrated verbatim from `.claude/skills/edna-interpret.md`; frontmatter updated.
- Slash-command syntax (`/edna:intake`, `/edna:run`, `/edna:interpret`) inside the bodies was preserved for Claude Code compatibility; the kebab-case names (`edna-intake`, `edna-run`, `edna-interpret`) are used in the H1 headings and frontmatter for Pi / Codex / Gemini CLI / OpenCode compatibility.

## Reproducibility

- Pipeline code: `main.nf`, `nextflow.config`, `modules/*.nf`, `bin/*`
- Per-stage tool envs: `env/{stage}/pixi.toml` (lockfile at `env/Manifest.toml` + `env/Project.toml`)
- Marker presets: `params/{16s,18s-v9,coi,12s}.json`
- Run artifacts: `results/{run_id}/` (gitignored)
- Skill spec: `SKILL.md` (this file), `preflight/edna-intake/SKILL.md`, `run/edna-run/SKILL.md`, `interpret/edna-interpret/SKILL.md`

## Verification

```bash
# 23 structural smoke tests (from the git source)
python3 test_smoke.py
# Expected: "OK" + "23 passed, 0 failed, 0 skipped (of 23)"

# From the deploy copy (~/.pi/agent/skills/nf-edna/) — git-hygiene checks are skipped automatically
python3 test_smoke.py
# Expected: "OK (skipped=3)" + "20 passed, 0 failed, 3 skipped (of 23)"

# Verify the git source ↔ deploy copy sync
diff -rq /home/cheahhl814/claude_workspace/bioinformatics/AIx-BIO/skills/nf-edna/ \
         /home/cheahhl814/.pi/agent/skills/nf-edna/
# Expected: only ".git" + ".gitignore" differences (deploy copy is intentionally not a git checkout)
```

## v1.1.0 backlog (non-blocking)

- **Signature library** — the 3 sub-skill bodies (migrated verbatim) don't yet have §Troubleshooting — Signature library sections. Add 3-5 entries per sub-skill.
- **Docs corpus** — ingest offline Markdown snapshots of upstream tool docs (cutadapt, NGmerge, VSEARCH, IDTAXA, decontam, phyloseq, vegan, Nextflow DSL2) into `docs-corpus/<tool>/README.md` via the `docs-ingest` skill + the `bioinfo-skill-creator` meta-skill's build flow.

## Handoff

After `interpret/edna-interpret` writes `<run_id>-report.md` and `narrative.md`, the run is complete. Common follow-ups:

- **Manuscript writing** → use [`literature-pipeline`](https://github.com/cheahhl814/literature-pipeline) to find citations, then draft with the `narrative.md` as a starting point.
- **GBIF publishing** → invoke `edna-gbif-publish` with the `<run_id>-report.md` and Darwin Core occurrence table.
- **Additional markers** → start a new run via `preflight/edna-intake` with a different `marker`.