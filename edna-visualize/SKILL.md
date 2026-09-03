---
name: eDNA-visualize
description: >-
  Publication-ready figure generation for environmental DNA (eDNA) metabarcoding
  analysis. Wraps three stages (1) raw counts → relative-abundance normalization via
  `normalize_abundance.R`, (2) CLR-transformed ComplexHeatmap heatmaps at
  Phylum/Family/Genus levels via `plot_heatmaps.R`, (3) high-contrast stacked-bar
  charts with rare-taxa lumping via `plot_stacked_bar.R`. Accepts any 4-level count
  table (nf-edna output OR any mia-compatible TSE). Mirrors the BettaMt
  ask-user-stop-points pattern. Use when the user asks to make eDNA figures, plot
  heatmap of microbial communities, stacked bar chart of ASVs, publication-ready
  eDNA plot, CLR heatmap, normalize ASV counts, Phylum/Family/Genus composition
  plot, or I have agglomerated counts, make figures. Pairs with `nf-edna`
  (upstream: produces the count tables) and `idtaxa-training` (sibling: produces
  the model used to generate classifications).
version: 1.1.4
updated: "2026-08-19"
triggers:
  - "make eDNA figures"
  - "plot heatmap of microbial communities"
  - "stacked bar chart of ASVs"
  - "publication-ready eDNA plot"
  - "CLR heatmap"
  - "normalize ASV counts"
  - "Phylum composition plot"
  - "Family composition plot"
  - "Genus composition plot"
  - "relative abundance normalization"
  - "mia visualization"
  - "ComplexHeatmap for microbiome"
  - "Community composition figure"
requires:
  - "R ≥ 4.2 with mia, miaViz, sechm, ComplexHeatmap, data.table, argparse, ggplot2, S4Vectors"
  - "pixi (curl -fsSL https://pixi.sh/install.sh | bash) — manages per-stage tool envs under env/"
---

# Sub-Skill: eDNA-visualize

> **v1.0.0.** Wraps three end-to-end stages for generating publication-ready eDNA figures: (1) counts → relative-abundance normalization, (2) CLR-transformed ComplexHeatmap heatmaps at 3 taxonomic levels, (3) high-contrast stacked-bar charts with rare-taxa lumping. Accepts any 4-level count table (nf-edna output OR any mia-compatible TSE). Built on the `mia` Bioconductor ecosystem (TreeSummarizedExperiment + miaViz + sechm + ComplexHeatmap).
>
> **This SKILL.md is a router.** It does not duplicate logic from the sub-skills. Its job is to ask: *what stage is the user at, and which sub-skill should they invoke next?*

## Audience

This sub-skill serves two simultaneous audiences:

1. **AI Coding Agents** — triggered by the phrases above. The agent must follow the strict evidence chain (Preflight → Run), respect the ask-user stop points (SP1–SP5 in preflight, SP1–SP4 in run), and write the artifacts each sub-skill specifies.
2. **Human bioinformaticians** — read this document as a guide. The sections explain *why* each stage exists and what the trade-offs are.

## When to Use This Skill

Use this sub-skill when you need to:

- Normalize **raw ASV counts** to **relative abundance** at Phylum / Family / Genus levels.
- Generate **CLR-transformed heatmaps** showing community composition across samples.
- Generate **stacked-bar charts** with the top-N taxa displayed individually and the rest lumped as "Other".
- Produce **publication-ready figures** for a 16S / 18S-V9 / COI / 12S eDNA dataset.

**Do NOT use this skill** if:

- You have raw FASTQ reads — start with `read-qc-trimming` then `nf-edna` first.
- You want a fully-managed Nextflow pipeline — use `nf-edna` (which can also produce figures).
- You want statistical analyses (alpha / beta diversity, differential abundance) — use `nf-edna`.

## 0. Orchestrator — detect phase, route to the right sub-skill

This sub-skill is a **router**. It does not run the R scripts itself. Its job is to ask: **"what stage is the user at, and which sub-skill should they invoke next?"**

### 0.1 Locate the run directory

By convention the agent writes handoff files to a run directory for the **visualization run under construction**. Default: a timestamped directory at the project root. Override with `RUN_DIR` env var.

```bash
# Example: visualizing an nf-edna output run
RUN_DIR=<your-run-dir>/run
```

### 0.2 Detect the user's phase

Try to detect automatically **before** asking:

```bash
# Phase detection ladder — first match wins
test -f "$RUN_DIR/run_summary.json"        && PHASE="run-done"
test -f "$RUN_DIR/preflight_evidence.json" && PHASE="run"
test -f "$RUN_DIR/preflight_verdict.txt"   && PHASE="run"
test -f "$RUN_DIR/preflight.md"            && PHASE="run"
: "${PHASE:=preflight}"
```

If auto-detection is ambiguous, ask the user one short question (see **SP0** in §0.5):

> Are you starting a fresh eDNA-visualize run, or continuing a previous one?
>
> - new run (no preflight yet)
> - preflight done; ready to run
> - Something failed and I need help debugging

### 0.5 Master ask-user stop point (SP0)

> **Evidence**: I observed `RUN_DIR = $RUN_DIR` and the phase-detection ladder returned `PHASE = $PHASE`.
> **Recommend**: `PHASE = preflight` if `$RUN_DIR/preflight.md` is absent, otherwise `PHASE = run`.
>
> Options:
> - **(A) Start preflight** (Recommended) — run `preflight/edna-visualize-preflight/SKILL.md` first
> - (B) Skip preflight, run directly — risky; missing mia/sechm packages will surface as cryptic `Rscript` errors
> - (C) Debug a previous failure — invoke the run sub-skill with `--debug` flag

**Auto-pick when**: `$RUN_DIR/preflight.md` is older than 24 h — auto-pick (A) "re-run preflight".

## 1. Inputs

- **Required inputs (gathered in preflight SP1–SP3)**:
  - 4 count tables: `--input_asv_counts`, `--input_phylum_counts`, `--input_family_counts`, `--input_genus_counts`
  - 3 taxonomy tables: `--input_phylum_taxonomy`, `--input_family_taxonomy`, `--input_genus_taxonomy` (for heatmaps)
  - Metadata file: `--metadata_file` (TSV with sample-id column + grouping variables)
  - Output directory: `--output_dir`
- **Optional inputs**:
  - `--group_by` (metadata column to merge replicates by averaging)
  - `--top_n` (default 50, for heatmaps)
  - `--top_n_taxa` (default 20, for stacked bars)

## 2. Outputs

| Artifact | Format | Producer script | Description |
| --- | --- | --- | --- |
| `asv_relabundance.tsv` | TSV | `normalize_abundance.R` (run SP2) | Normalized ASV-level relative abundance |
| `phylum_relabundance.tsv` | TSV | `normalize_abundance.R` | Phylum-level relative abundance |
| `family_relabundance.tsv` | TSV | `normalize_abundance.R` | Family-level relative abundance |
| `genus_relabundance.tsv` | TSV | `normalize_abundance.R` | Genus-level relative abundance |
| `heatmap_phylum.pdf` | PDF | `plot_heatmaps.R` (run SP3) | CLR-transformed heatmap (Phylum) |
| `heatmap_family.pdf` | PDF | `plot_heatmaps.R` | CLR-transformed heatmap (Family) |
| `heatmap_genus.pdf` | PDF | `plot_heatmaps.R` | CLR-transformed heatmap (Genus) |
| `stacked_bar_chart_phylum.pdf` | PDF | `plot_stacked_bar.R` (run SP4) | Stacked bar (Phylum, top-20) |
| `stacked_bar_chart_family.pdf` | PDF | `plot_stacked_bar.R` | Stacked bar (Family, top-20) |
| `stacked_bar_chart_genus.pdf` | PDF | `plot_stacked_bar.R` | Stacked bar (Genus, top-20) |
| `run_summary.json` | JSON | this skill (run SP5) | Compact, LLM-loadable summary |

## 3. The 3-stage workflow

```
   ┌──────────────────────────────────────────┐
   │ Stage 1: counts → relative abundance     │
   │ (normalize_abundance.R)                  │
   └────────────────────┬─────────────────────┘
                        │ 4 × relabundance.tsv
                        ▼
   ┌──────────────────────────────────────────┐
   │ Stage 2: heatmaps                        │
   │ (plot_heatmaps.R)                        │   ← CLR-transformed
   └────────────────────┬─────────────────────┘     sechm heatmaps
                        │ 3 × heatmap_*.pdf
                        ▼
   ┌──────────────────────────────────────────┐
   │ Stage 3: stacked bars                    │
   │ (plot_stacked_bar.R)                     │   ← miaViz plotAbundance
   └──────────────────────────────────────────┘     top-N + Other
```

**Stage 1** is required (the heatmaps and stacked bars expect relative-abundance input, not raw counts).
**Stage 2 + 3** are independent — can run separately or together.

## 4. Quick start

```bash
# 1. Preflight — validates inputs + mia/sechm packages
invoke_skill preflight/edna-visualize-preflight
#    → produces $RUN_DIR/preflight.md + preflight_evidence.json

# 2. Run — stages 1-3
invoke_skill run/edna-visualize-run
#    → produces $RUN_DIR/{4 relabundance.tsv, 3 heatmap.pdf, 3 stacked_bar.pdf, run_summary.json}
```

## 5. Sub-skills

### Preflight (validate inputs + toolchain)

→ `preflight/edna-visualize-preflight/SKILL.md`

Validates:
- SP1 — All 4 count tables + 3 taxonomy tables + metadata file exist and parse
- SP2 — Sample IDs are consistent across all 8 tables (intersection is non-empty)
- SP3 — `mia`, `miaViz`, `sechm`, `ComplexHeatmap` available in pixi env
- SP4 — Output directory writable
- SP5 — `--group_by` column exists in metadata (if specified)

Verdict: `GO` / `GO-WITH-WARNINGS` / `NO-GO`.

### Run (execute the 3 stages)

→ `run/edna-visualize-run/SKILL.md`

Phases:
- SP1 — Confirm preflight verdict is `GO` or `GO-WITH-WARNINGS`
- SP2 — **Stage 1**: `pixi run --manifest-path env/visualization/pixi.toml Rscript bin/normalize_abundance.R ...`
- SP3 — **Stage 2**: `pixi run ... Rscript bin/plot_heatmaps.R ...` (heatmaps)
- SP4 — **Stage 3**: `pixi run ... Rscript bin/plot_stacked_bar.R ...` (stacked bars)
- SP5 — Write `run_summary.json` for downstream consumers

## 6. Where this fits in the wider skill graph

```
                 ┌──────────────────┐
                 │     nf-edna      │  (or any mia-compatible source)
                 └────────┬─────────┘
                          │ 4 count tables + 3 taxonomy tables + metadata
                          ▼
                 ┌──────────────────┐
                 │  eDNA-visualize  │  (this skill)
                 │  (figures)       │
                 └────────┬─────────┘
                          │ 4 relabundance TSV + 6 PDF figures
                          ▼
                 ┌──────────────────┐
                 │  Manuscripts /   │
                 │  Lab meetings /  │
                 │  GBIF reports    │
                 └──────────────────┘
```

- **Upstream**: any source producing 4-level count tables (nf-edna `classify.nf` agglomerate_data output, or manual `mia` workflows).
- **Downstream**: figures go directly into manuscripts, lab-meeting slides, or supplementary materials of GBIF-published reports.
- **Parallel**: `idtaxa-training` produces the classifier; this skill consumes the resulting classifications.

## 7. Troubleshooting — Signature library

| Signature in stderr / log | Likely cause | Suggested fix |
| --- | --- | --- |
| `Error: No common samples between relative abundance table and metadata` | Sample-ID mismatch between count tables and metadata | Verify `head -1 metadata.tsv` matches sample IDs in count tables; rename column to `sample-id` if needed |
| `Error in library(sechm) : there is no package called 'sechm'` | sechm not in pixi env | `pixi add --manifest-path env/visualization/pixi.toml bioconductor-sechm` |
| `Error in plotAbundance: 'rank' must be a column in rowData(tse)` | Taxonomy table missing the expected rank column | Verify taxonomy table has a column matching the level name (`Phylum` / `Family` / `Genus`) |
| `PDF device: cannot open file` | Output directory not writable | Re-run preflight SP4 to identify a writable output dir |
| `Rscript: command not found` | pixi env not activated | Re-invoke with `pixi run --manifest-path env/visualization/pixi.toml ...` instead of bare `Rscript` |
| `Heatmap is empty (no features passed the top_n filter)` | `--top_n` is too small for the dataset | Re-run with `--top_n 100` (default 50); or check that count table is not empty |
| `Stacked bar shows only "Other" (no top-N taxa)` | All taxa are below `--top_n_taxa` threshold (dataset has very even distribution) | Re-run with `--top_n_taxa 5` (default 20); or check that count table is not uniform |

## 8. Related skills

- **nf-edna** (`~/.pi/agent/skills/nf-edna/`) — upstream: produces the 4 count tables + 3 taxonomy tables via `classify.nf:agglomerate_data`
- **idtaxa-training** (`~/.pi/agent/skills/idtaxa-training/`) — sibling: produces the classifier that generated the classifications being visualized
- **read-qc-trimming** (`~/.pi/agent/skills/read-qc-trimming/`) — upstream: pre-processes raw reads
- **html-template-pack** (`~/.pi/agent/skills/html-template-pack/`) — downstream: package figures into a reviewable HTML report

## Verification

- [ ] `preflight/edna-visualize-preflight/SKILL.md` produces a `GO` / `GO-WITH-WARNINGS` verdict before any stage script is invoked.
- [ ] The exact `pixi run Rscript ...` command for each stage was shown to the user and explicitly confirmed (Step invariant).
- [ ] All 4 normalized TSVs + 3 heatmap PDFs + 3 stacked-bar PDFs are written.
- [ ] `run_summary.json` is written at the end of the run.

## Invariants

- **Never** invoke a stage script without showing the full command first and waiting for explicit confirmation.
- **Never** skip the preflight sub-skill — its verdict gates the run sub-skill.
- **Always** verify sample IDs are consistent across all input tables before plotting (preflight SP2).