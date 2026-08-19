---
name: nf-edna
description: End-to-end agent orchestration of the nf-edna Nextflow DSL2 pipeline for environmental DNA (eDNA) metabarcoding analysis across four marker genes — 16S (Bacteria/Archaea), 18S-V9, COI, and 12S (Eukaryota). Drives intake → QC → denoise → classify → diversity → association stages with marker-specific presets, then turns outputs into a structured report. Mirrors the BettaMt ask-user-stop-points pattern and the canonical `bacterial-genome-analysis` evidence chain. Use when the user asks to "run an eDNA metabarcoding analysis", "process 16S/18S/COI/12S amplicon reads", "interpret eDNA results", or "set up an eDNA pipeline run". Builds on read-qc-trimming (raw-read QC upstream) and pairs with edna-gbif-publish (downstream GBIF Darwin Core publishing).
version: 1.1.3
updated: "2026-08-19"
triggers:
  - "run eDNA metabarcoding"
  - "process 16S amplicon reads"
  - "process 18S V9 reads"
  - "process COI reads"
  - "process 12S reads"
  - "eDNA ASV inference"
  - "taxonomic classification 16S"
  - "eDNA alpha beta diversity"
  - "eDNA differential abundance"
  - "IDTAXA classification"
  - "VSEARCH UNOISE3"
  - "metabarcoding pipeline"
  - "nf-edna"
requires:
  - "Nextflow ≥ 23.10.0 (DSL2-compatible release)"
  - "Pixi (curl -fsSL https://pixi.sh/install.sh | bash) — manages per-stage tool envs under env/"
  - "git"
---

# Meta-Skill: nf-edna

> **v1.1.3.** Adds a third auxiliary sub-skill: `reference-db/` (curated catalog of direct-download URLs for the 4 nf-edna marker reference databases — SILVA 16S/18S, PR2 18S, MIDORI2/BOLD COI, MitoFish 12S — with workflows for retrieval and DECIPHER training when no pre-trained file exists). The catalog includes DECIPHER-pre-trained files (load directly via patched `bin/idtaxa_rds.R`), pre-trained trainingFiles from the DECIPHER Downloads page (SILVA, PR2, UNITE, GTDB, RDP, Contax, Warcup, Fungal LSU), and raw references (MIDORI2, BOLD, MitoFish) that chain to `idtaxa-training` for DECIPHER training. 6-stop-point preflight (marker, disk, URL connectivity, assets dir, license acceptance, training prerequisites) + 4-stop-point run sub-skill (download, validate, train-if-needed). 25-test smoke test suite. Composability section now references the new sub-skill.
>
> **v1.1.2.** Adds two auxiliary sub-skills for tasks the pipeline itself does not cover: `idtaxa-training/` (training a DECIPHER IDTAXA classifier from scratch — NCBI FASTA → DECIPHER headers → trained `.rds` → species list + classification; also includes a patched `bin/idtaxa_rds.R` that auto-detects DECIPHER RDX3 binary format) and `edna-visualize/` (publication-ready figure generation from the 4-level count tables — normalize → CLR heatmaps → stacked bars). Both live under this repo as standalone sub-directories with their own preflight + run sub-skills, smoke tests, and signature libraries. The main 5-stage pipeline (`preflight/edna-intake` → `run/edna-run` → `interpret/edna-interpret`) is unchanged. Composability section in this SKILL.md now references both new sub-skills.
>
> **v1.1.1.** Adds support for **DECIPHER RDX3 IDTAXA training files** (e.g., SILVA `SILVA_SSU_r138.2.rdata`, XZ- or gzip-compressed). `bin/idtaxa_rds.R` now auto-detects three model formats via magic-byte sniffing: standard RDS, gzipped RDS, and DECIPHER's RDX3 binary format (the 5-byte `RDX3\n` header is skipped before `unserialize()`). No user action needed — the same `idtaxa_model` path that previously broke on RDX3 files now loads transparently and caches a converted `.converted.rds` next to the original. Finding 7 added to `run/edna-run/SKILL.md` signature library.
>
> **v1.1.0.** Adds the canonical BettaMt / `bettamt-preflight` structure to all 3 sub-skills (§0 Inputs/Outputs contract, §0.5 Ask-User Stop Points with Evidence + Recommend + Options format, §Audience, §When to Use / §Do NOT use this skill, §Troubleshooting — Signature library, GO / GO-WITH-WARNINGS / NO-GO verdict gate). Master `§0.5 SP0` now has an explicit `Auto-pick when` operating rule. The 3 sub-skill procedure bodies (the Steps) are unchanged from v1.0.0 — only the structured wrappers were added. Mirrors `bioinfo-skill-creator/preflight/skill-creator-preflight/SKILL.md`.
>
> **This SKILL.md is a router.** It does not duplicate logic from the sub-skills. Its job is to ask: *what stage is the user at, and which sub-skill should they invoke next?*

## Audience

This meta-skill serves two simultaneous audiences:

1. **AI Coding Agents** — triggered by the phrases above. The agent must follow the strict evidence chain (Preflight → Run → Interpret), respect each sub-skill's decision points, and write the `pipeline_state.json`, `run_summary.json`, and `<run_id>-report.md` artifacts the sub-skills specify.
2. **Human Users (eDNA scientists)** — read this document as a workflow guide. The sections explain *why* each phase exists and *what* trade-offs apply at each marker preset.

## When to Use This Skill

Use this meta-skill when you need to:

- Run an **eDNA metabarcoding analysis** for one of the four supported markers (16S, 18S-V9, COI, 12S).
- Execute the nf-edna pipeline in **stages** (QC, denoise, classify, diversity, association) with `-resume` reuse.
- Produce a **structured report** and **narrative Results-section summary** from completed pipeline outputs.
- Conduct **differential abundance**, **taxon-environment**, or **taxon-taxon correlation** analyses on eDNA community tables.
- Publish eDNA occurrence data downstream (chains to the `edna-gbif-publish` skill).

**Do NOT use this skill** if:

- You have **raw reads that have not been QC-trimmed yet** — use `read-qc-trimming` first; this skill expects either raw reads *or* a `pipeline_state.json` from a prior intake.
- You want to author a Nextflow pipeline from scratch — use `nextflow-pipelines` instead.
- You are analysing shotgun metagenomics (different paradigm; use `gene-quantification` and downstream skills).
- Your marker is not one of the four supported — the marker-specific behavior is hardcoded in `params/{16s,18s-v9,coi,12s}.json`.

## 0. Orchestrator — detect stage, route to the right sub-skill

### 0.1 Locate the run directory

By convention the agent writes run artifacts to `results/{run_id}/`. The `pipeline_state.json` lives at `results/{run_id}/pipeline_state.json`. Override with the `RUN_DIR` env var or by passing `--run-dir` to the sub-skill.

### 0.2 Detect the user's stage

Try to detect automatically **before** asking:

```bash
# Stage detection ladder — first match wins
test -f "$RUN_DIR/results/{run_id}/pipeline_state.json" || STAGE="intake"      # no state → start intake
test -f "$RUN_DIR/results/{run_id}/run_summary.json"   && STAGE="interpret"     # summary exists → run interpret
test -n "$(jq -r '.completed_stages | select(contains([\"association\"]))' "$RUN_DIR/results/{run_id}/pipeline_state.json" 2>/dev/null)" \
                                                          && STAGE="interpret"   # full pipeline done → interpret
test -n "$(jq -r '.completed_stages | select(contains([\"classify\"]))' "$RUN_DIR/results/{run_id}/pipeline_state.json" 2>/dev/null)" \
                                                          && STAGE="interpret-or-continue"  # partial → ask
: "${STAGE:=intake}"
```

If auto-detection is ambiguous, ask the user one short question (see **SP0** below):

> Are you starting a new eDNA run, or continuing a previous one?
>
> - new run (no `pipeline_state.json` yet) → `preflight/edna-intake`
> - I have cleaned reads and a marker in mind → `preflight/edna-intake`
> - I have a `pipeline_state.json` and want to run more stages → `run/edna-run`
> - My run is complete and I want a report → `interpret/edna-interpret`
> - Something failed and I need help debugging → route to `debug` (not yet implemented; in v1.0.0, inspect `run.log` and re-invoke `run/edna-run` with `--resume`)

### 0.3 Stage → sub-skill routing table

| Detected stage | Route to | Output artifact |
| --- | --- | --- |
| `intake` | `preflight/edna-intake/SKILL.md` | `results/{run_id}/pipeline_state.json` |
| `run` (any stage pending) | `run/edna-run/SKILL.md` | `results/{run_id}/{stage}_output/...` + updated `pipeline_state.json` |
| `interpret` (≥ classify complete) | `interpret/edna-interpret/SKILL.md` | `results/{run_id}/<run_id>-report.md` + `narrative.md` |
| `interpret-or-continue` | ask user | — |
| `debug` | re-invoke `run/edna-run` with `--resume` after inspecting logs | — |

### 0.4 Bash vs Nextflow decision

**Default: bash recipes inside `run/edna-run` invoke `nextflow run` under the hood.** The `run/edna-run` sub-skill constructs the `nextflow run main.nf -params-file params/{marker}.json -params-file ...` command and shows it to the user before execution. This is the same model as `bacterial-genome-analysis`'s `run/genome-run` sub-skill.

If you need **production / HPC / cohort** runs (sge, slurm, lsf, AWS Batch), see **§Nextflow profiles** in `run/edna-run/SKILL.md` for the available profile names.

### 0.5 Master ask-user stop point (SP0)

This orchestrator has **one** user-facing stop point at the routing layer (SP0). All other stop points live inside the sub-skills. SP0 fires only when stage auto-detection is ambiguous. The format is **Evidence + Recommend + Options**:

> I see `<evidence>`. I recommend `<recommendation>`. Which of `<A/B/C>` do you want?

Do not ask "what do you want?" — present the evidence and a recommendation, then 2–4 concrete options.

#### SP0 — Stage auto-detection ambiguous

| Trigger | Evidence check | Action |
| --- | --- | --- |
| `pipeline_state.json` exists with ≥ 3 completed stages AND user did not specify "intake" / "run" / "interpret" | Multiple valid routings | Ask: "I see `<run_id>` with completed stages `<list>`. Pick: (A) start a **new run** via `preflight/edna-intake`, (B) **continue** the existing run via `run/edna-run`, (C) **interpret** completed results via `interpret/edna-interpret`, (D) something else (debug / fix / etc.) — tell me" |
| `pipeline_state.json` is missing AND user mentions a `run_id` | State file lost or never written | Ask: "I see a `run_id` reference but no `results/{run_id}/pipeline_state.json`. Pick: (A) re-run `preflight/edna-intake` to recreate it (you'll re-supply all parameters), (B) point me at the correct location — the state file is somewhere else, (C) abort" |

**Auto-pick when**: stage detection ladder resolves unambiguously (no `pipeline_state.json` → `intake`; state exists with `completed_stages ⊆ {qc, denoise, classify}` → `run`; state exists with `classify ∈ completed_stages` → `interpret`). No ask.

### Operating rule

> **Auto-pick when the evidence is unambiguous; ask when the agent genuinely cannot decide.** When asking, present the evidence first, then the recommendation, then 2–4 concrete options. Do not ask "what do you want?" — ask "I see X, recommend Y, which one of A/B/C?"

## Description

This meta-skill orchestrates the nf-edna Nextflow DSL2 pipeline through three phases:

1. **`preflight/edna-intake`** — gather run parameters (marker, primer pair, metadata, IDTAXA model, run_id), validate that all required input files exist, write `results/{run_id}/pipeline_state.json`.
2. **`run/edna-run`** — read `pipeline_state.json`, determine the next stage(s) to run (`qc` → `denoise` → `classify` → `diversity` → `association`), construct and execute the `nextflow run` command with the correct `-params-file` chain, monitor progress, update `pipeline_state.json` after each stage completes.
3. **`interpret/edna-interpret`** — read `results/{run_id}/run_summary.json` (produced by `bin/summarise_run.py`), turn it into a structured `<run_id>-report.md` and a plain-language `narrative.md` suitable for a manuscript Results section, then enter an interactive Q&A loop.

Each phase ships its own **ask-user stop points** (SP1, SP2, …) for decision ambiguity inside the phase (e.g. primer mismatch tolerance, geocuration on/off, DAA method choice).

## Prerequisites

- **Nextflow ≥ 23.10.0** (DSL2-compatible release). Install via `curl -s https://get.nextflow.io | bash`.
- **Pixi** — manages per-stage tool environments under `env/{qc,denoise,classification,database,diversity,geocuration,association}/pixi.toml`. First run of a stage will resolve and cache its pixi env automatically; no manual `conda`/`mamba` setup.
- **Reference assets per marker** — trained IDTAXA models, taxonomy tables. Live under `assets/{16s,18s-v9,coi,12s}/` and are gitignored (supply your own per `.gitignore`'s tracked patterns).
- **git** — for committing handoff files (`pipeline_state.json`, `run_summary.json`, `<run_id>-report.md`).

## Marker presets (`params/`)

| Preset        | Marker | Length range | Kingdoms          | DAA/correlation level | Geocurate |
| ------------- | ------ | ------------ | ----------------- | --------------------- | --------- |
| `16s.json`    | 16S    | 350–550 bp   | Bacteria, Archaea | Genus                 | off       |
| `18s-v9.json` | 18S-V9 | 100–180 bp   | Eukaryota         | Species               | off       |
| `coi.json`    | COI    | 290–340 bp   | Eukaryota         | Species               | on        |
| `12s.json`    | 12S    | 150–200 bp   | Eukaryota         | Species               | on        |

`-params-file` flags merge left-to-right (last wins). Always pass the marker preset **first**, then the run-specific overrides (manifest, metadata, IDTAXA model, run_id, etc.) **second**.

## Output artifacts

For a complete run (`run_id = 16s-20260819-siteA`):

```
results/16s-20260819-siteA/
├── pipeline_state.json           ← written by preflight/edna-intake, updated by run/edna-run
├── run.log                       ← Nextflow execution log
├── qc_output/                    ← cutadapt + FastQC outputs
├── denoise_output/               ← NGmerge + UNOISE3 + decontam outputs
├── classify_output/              ← IDTAXA + geocuration outputs
├── diversity_output/             ← tree + alpha/beta diversity outputs
├── association_output/           ← DAA + correlation outputs
├── run_summary.json              ← compact summary for LLM context (bin/summarise_run.py)
├── 16s-20260819-siteA-report.md  ← structured report (interpret/edna-interpret)
└── narrative.md                  ← plain-language Results-section draft
```

## Composability with other AiX-BIO skills

| Skill | When to chain |
| --- | --- |
| `read-qc-trimming` | Run **before** `preflight/edna-intake` if your reads are raw (untrimmed). nf-edna's `qc` stage does primer trimming; if your reads also need adapter trimming + quality filtering, do that first. |
| `pixi-env-mgmt` | Use to add/modify the per-stage pixi envs under `env/`. |
| `nextflow-pipelines` | Reference for the DSL2 idioms used in `modules/` and `main.nf`. |
| `edna-gbif-publish` | After `interpret/edna-interpret`, publish occurrence data to GBIF. |
| `geocoding` | Used internally by `bin/geocurate_fetch.R` if you enable geocuration for a run. |
| **`idtaxa-training`** (this repo: `idtaxa-training/`) | Run **before** the first-ever nf-edna run if you don't yet have an IDTAXA `.rds` model. Wraps `prepare_ncbi_fasta_for_idtaxa.R` + `train_idtaxa_model.R` + `extract_scientific_names.jl` + (patched) `bin/idtaxa_rds.R`. Also useful for loading existing DECIPHER trainingFiles (e.g., SILVA `SILVA_SSU_r138.2.rdata`) without modification. |
| **`edna-visualize`** (this repo: `edna-visualize/`) | Run **after** `interpret/edna-interpret` if you want publication-ready figures beyond the canonical `narrative.md` plots. Wraps `normalize_abundance.R` + `plot_heatmaps.R` + `plot_stacked_bar.R`. Accepts any 4-level count tables (nf-edna output OR any mia-compatible source). |

## Handoff contract

Each sub-skill produces machine-readable artifacts the next phase consumes:

| From | To | Artifact |
| --- | --- | --- |
| `preflight/edna-intake` | `run/edna-run` | `results/{run_id}/pipeline_state.json` (with `pipeline`, `marker`, `params`, `completed_stages`, `last_stage`) |
| `run/edna-run` | `interpret/edna-interpret` | `results/{run_id}/run_summary.json` (compact, LLM-loadable) |
| `run/edna-run` | `next run/edna-run` invocation | updated `pipeline_state.json` with the new `completed_stages` |
| `interpret/edna-interpret` | human / manuscript | `results/{run_id}/<run_id>-report.md` + `narrative.md` |

## What NOT to do

- Do **not** skip `preflight/edna-intake`. The pipeline expects a complete `pipeline_state.json` with every parameter validated.
- Do **not** edit `params/{marker}.json` to add a new marker — the marker-specific behavior is hardcoded across `modules/` and `bin/` scripts. Add a new marker only via the canonical pipeline extension procedure (out of scope for v1.0.0).
- Do **not** delete `pipeline_state.json` mid-run. Nextflow's `-resume` and the sub-skill's stage-detection ladder both depend on it.
- Do **not** commit `assets/`, `results/`, `work/`, `.nextflow.log*`, or `*.fq.gz` — see `.gitignore`.

## Reproducibility

- Pipeline code: `main.nf`, `nextflow.config`, `modules/*.nf`, `bin/*`
- Per-stage tool envs: `env/{stage}/pixi.toml` (lockfile at `env/Manifest.toml` + `env/Project.toml`)
- Marker presets: `params/{16s,18s-v9,coi,12s}.json`
- Run artifacts: `results/{run_id}/` (gitignored)
- Skill spec: `SKILL.md` (this file), `preflight/edna-intake/SKILL.md`, `run/edna-run/SKILL.md`, `interpret/edna-interpret/SKILL.md`

## Handoff

After `interpret/edna-interpret` writes `<run_id>-report.md` and `narrative.md`, the run is complete. Common follow-ups:

- **Manuscript writing** → use `literature-pipeline` to find citations, then draft with the `narrative.md` as a starting point.
- **GBIF publishing** → invoke `edna-gbif-publish` with the `<run_id>-report.md` and Darwin Core occurrence table.
- **Additional markers** → start a new run via `preflight/edna-intake` with a different `marker`.
