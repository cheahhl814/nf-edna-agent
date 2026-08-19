---
name: nf-edna-nextflow-runner
description: Nextflow DSL2 pipeline (v1.1.3) for nf-edna eDNA metabarcoding analysis. Wraps the 5 stages (QC → DENOISE → CLASSIFY → DIVERSITY → ASSOCIATION) across 4 markers (16S / 18S-V9 / COI / 12S). This is the **primary pipeline** of nf-edna (not an opt-in wrapper — bash recipes in `run/edna-run` invoke `nextflow run runners/nextflow-runner/main.nf` under the hood). Provides 5 modules (qc.nf / denoise.nf / classify.nf / diversity.nf / association.nf) + 4 marker-specific params presets (params/{16s,18s-v9,coi,12s}.json) + 7 per-stage pixi envs (env/{qc,denoise,classification,database,diversity,geocuration,association}/pixi.toml) + 14 R/Julia scripts (bin/) wired into the modules. Mirrors the `bacterial-genome-analysis` `runners/nextflow-runner/` convention. Use when the user says "run the nf-edna pipeline", "nextflow run nf-edna", "execute the eDNA metabarcoding pipeline", or invokes any stage via Nextflow.
version: 1.1.4
updated: "2026-08-19"
triggers:
  - "run nf-edna pipeline"
  - "nextflow run nf-edna"
  - "execute eDNA pipeline"
  - "run nextflow main.nf"
  - "nextflow metabarcoding"
  - "eDNA Nextflow pipeline"
  - "nf-edna runner"
  - "nf-edna pipeline"
---

# Nextflow Runner — nf-edna (v1.1.3)

This directory contains the **primary Nextflow DSL2 pipeline** of nf-edna. It is the engine that the bash recipes in `run/edna-run/` invoke via `nextflow run runners/nextflow-runner/main.nf`.

## Audience

1. **AI Coding Agents** — trigger via the phrases above. When invoked, follow the run sub-skill's protocol: construct the `nextflow run` command, show it to the user, execute after explicit confirmation.
2. **Human bioinformaticians** — for production runs, HPC execution, or cohort analysis. Use `-resume` for long pipelines; use `-stub-run` for smoke testing.

## When to Use

**Do** use the runner when:

- You are running the full nf-edna pipeline (5 stages).
- You want `-resume` for long pipelines.
- You want nf-core-style trace / timeline / reports.
- You want to run ≥ 3 samples in batch.

**Do NOT** use the runner when:

- You only need a single stage (use the per-stage sub-skill: `run/edna-run` with `-entry QC_ONLY`, `DENOISE_ONLY`, etc.).
- You just want to inspect or test the pipeline without running it (use `nextflow -stub-run`).
- You want to use the auxiliary sub-skills only (`idtaxa-training`, `edna-visualize`, `reference-db`) — these are script-based and don't need Nextflow.

## Directory structure

```
runners/nextflow-runner/
├── main.nf                          # Workflow entry point (5 stages + 4 named entry points)
├── nextflow.config                  # Process defaults (cpus/memory/time), manifest block
├── modules/
│   ├── qc.nf                        # cutadapt + FastQC
│   ├── denoise.nf                   # NGmerge + VSEARCH UNOISE3 + decontam
│   ├── classify.nf                  # IDTAXA + confidence filter + agglomeration + geocuration
│   ├── diversity.nf                 # tree + alpha + beta + community typing
│   └── association.nf               # differential abundance + correlations
├── params/
│   ├── 16s.json                     # 16S marker preset (Bacteria, Archaea, 350-550 bp)
│   ├── 18s-v9.json                  # 18S-V9 marker preset (Eukaryota, 100-180 bp)
│   ├── coi.json                     # COI marker preset (Eukaryota, 290-340 bp)
│   └── 12s.json                     # 12S marker preset (Eukaryota, 150-200 bp)
├── env/
│   ├── qc/pixi.toml                 # FastQC + cutadapt
│   ├── denoise/pixi.toml            # NGmerge + VSEARCH
│   ├── classification/pixi.toml     # R + DECIPHER + Bioconductor (DECIPHER, mia, miaViz, sechm)
│   ├── database/pixi.toml           # R + DECIPHER + taxonomizr + rgbif + robis
│   ├── diversity/pixi.toml          # R + phyloseq + vegan
│   ├── geocuration/pixi.toml        # R + rgbif + robis + sf
│   └── association/pixi.toml        # R + mia + ALDEx2 + microbiome + corrplot
└── bin/
    ├── agglomerate_data.R            # classify.nf: ASV → rank aggregation (Phylum/Family/Genus)
    ├── alpha_diversity.R             # diversity.nf: Shannon, Simpson, observed richness
    ├── beta_diversity.R              # diversity.nf: PCoA, PERMANOVA
    ├── community_typing.R            # diversity.nf: hierarchical clustering
    ├── correlation_analysis.R        # association.nf: taxon-environment correlations
    ├── decontam.jl                   # denoise.nf: prevalence-based decontamination
    ├── differential_abundance.R      # association.nf: ALDEx2, LinDA, MaAsLin2
    ├── filter_idtaxa_by_confidence.jl# classify.nf: drop low-confidence ASVs
    ├── filter_table.jl               # denoise.nf: prevalence/sample filters
    ├── geocurate_check.R             # classify.nf: spatial concordance check
    ├── geocurate_fetch.R             # classify.nf: GBIF/OBIS occurrence download
    ├── idtaxa_rds.R                  # classify.nf: IDTAXA classification (patched for RDX3 + XZ)
    ├── merge_tables.R                # denoise.nf: feature-table + taxonomy merge
    └── root_tree.R                   # diversity.nf: phylogenetic tree rooting
```

## Quick start

```bash
# From the nf-edna skill root
cd ~/.pi/agent/skills/nf-edna

# Run with marker preset
nextflow run runners/nextflow-runner/main.nf \
  -params-file runners/nextflow-runner/params/16s.json \
  -params-file path/to/run-specific-overrides.json

# Stub-run (smoke test, no actual computation)
nextflow run runners/nextflow-runner/main.nf \
  -params-file runners/nextflow-runner/params/12s.json \
  -stub-run

# Resume an interrupted run
nextflow run runners/nextflow-runner/main.nf -resume

# Single stage only
nextflow run runners/nextflow-runner/main.nf -entry DENOISE_ONLY \
  -params-file runners/nextflow-runner/params/16s.json
```

## Workflow entry points

| Entry point | Stages | Use when |
|---|---|---|
| (default) | QC → DENOISE → CLASSIFY → DIVERSITY → ASSOCIATION | Full pipeline |
| `QC_ONLY` | QC | Primer trimming + FastQC only |
| `DENOISE_ONLY` | QC → DENOISE | Pair-merge + ASV inference + decontam |
| `CLASSIFY_ONLY` | QC → DENOISE → CLASSIFY | IDTAXA classification + agglomeration + (optional) geocuration |
| `DIVERSITY_ONLY` | QC → DENOISE → CLASSIFY → DIVERSITY | + alpha/beta diversity, community typing |

## Per-stage pixi environments

Each Nextflow process that needs a specific toolchain invokes it via `pixi run --manifest-path ${baseDir}/runners/nextflow-runner/env/<stage>/pixi.toml <command>`. The pixi envs are resolved on first run and cached in `.pixi/`. No manual `conda` / `mamba` setup needed.

| Stage | Tools |
|---|---|
| `qc` | FastQC + cutadapt |
| `denoise` | NGmerge + VSEARCH UNOISE3 |
| `classification` | R + DECIPHER + Bioconductor (DECIPHER, mia, miaViz, sechm, ComplexHeatmap) |
| `database` | R + DECIPHER + taxonomizr + rgbif + robis (reserved for reference DB preparation; not used by current modules) |
| `diversity` | R + phyloseq + vegan |
| `geocuration` | R + rgbif + robis + sf |
| `association` | R + mia + ALDEx2 + LinDA + MaAsLin2 |

## Bin scripts (wired into Nextflow modules)

14 R/Julia scripts in `bin/` are invoked by the modules via `${baseDir}/runners/nextflow-runner/bin/<script>`. Note that this is separate from the **sub-skill bin/** at the nf-edna root (which has 7 scripts used by `idtaxa-training`, `edna-visualize`, and `reference-db`). The two `bin/` directories serve different purposes:

| Directory | Used by | Scripts |
|---|---|---|
| `runners/nextflow-runner/bin/` | Nextflow modules | 14 (decontam, merge_tables, alpha_diversity, …) |
| `bin/` (nf-edna root) | Auxiliary sub-skills (idtaxa-training, edna-visualize, reference-db) | 7 (prepare_ncbi_fasta, train_idtaxa_model, plot_heatmaps, …) |

The `bin/idtaxa_rds.R` script exists in BOTH directories because both the Nextflow pipeline (via `classify.nf`) and the `idtaxa-training` sub-skill (for standalone classification) need it. They are kept in sync via the `idtaxa-training` sub-skill's bin/ being a copy of the runner's bin/.

## Marker presets (params/)

Each marker has a JSON preset with marker-specific defaults. Override individual fields via a second `-params-file`.

| Marker | Length range | Kingdoms | DAA/correlation level | Geocurate |
|---|---|---|---|---|
| `16s.json` | 350–550 bp | Bacteria, Archaea | Genus | off |
| `18s-v9.json` | 100–180 bp | Eukaryota | Species | off |
| `coi.json` | 290–340 bp | Eukaryota | Species | on |
| `12s.json` | 150–200 bp | Eukaryota | Species | on |

## Related skills

- **preflight/edna-intake** (this repo: `preflight/edna-intake/`) — invokes this runner via `run/edna-run`
- **run/edna-run** (this repo: `run/edna-run/`) — constructs `nextflow run` commands and shows them to the user
- **interpret/edna-interpret** (this repo: `interpret/edna-interpret/`) — reads `results/{run_id}/run_summary.json` (written by `bin/summarise_run.py` at the end of the run)
- **idtaxa-training** (this repo: `idtaxa-training/`) — produces the IDTAXA model used by `classify.nf`
- **edna-visualize** (this repo: `edna-visualize/`) — produces figures from classification outputs
- **reference-db** (this repo: `reference-db/`) — catalogs reference DB downloads (SILVA, PR2, MitoFish, MIDORI2, BOLD)
- **bacterial-genome-analysis** (`~/.pi/agent/skills/bacterial-genome-analysis/runners/nextflow-runner/`) — the convention this directory mirrors