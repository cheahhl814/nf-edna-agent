---
name: edna-visualize-run
description: >-
  Executes the 3-stage eDNA-visualize workflow after preflight has passed
  (1) counts → relative abundance via `normalize_abundance.R`,
  (2) CLR-transformed ComplexHeatmap heatmaps at Phylum/Family/Genus levels via `plot_heatmaps.R`,
  (3) high-contrast stacked-bar charts via `plot_stacked_bar.R`.
  Writes `run_summary.json` for downstream consumers.
version: 1.1.4
updated: "2026-08-19"
triggers:
  - "run eDNA-visualize"
  - "execute eDNA figure generation"
  - "make publication-ready eDNA plots"
requires:
  - "Preflight verdict = GO or GO-WITH-WARNINGS (gates this sub-skill)"
  - "pixi (runs the R scripts)"
  - "R ≥ 4.2 with mia, miaViz, sechm, ComplexHeatmap, data.table, ggplot2, S4Vectors, argparse"
---

# Sub-Skill: edna-visualize-run

## Audience

This sub-skill serves two simultaneous audiences:

1. **AI Coding Agents** — invoked by the parent `eDNA-visualize` orchestrator after preflight verdict is `GO` / `GO-WITH-WARNINGS`. The agent must run all 4 stop points in order, write `run_summary.json`, and not modify any artifact after it has been written.
2. **Human bioinformaticians** — read this document to understand the run phases and what to expect at each stage.

## When to Use

Use this sub-skill **after** `preflight/edna-visualize-preflight` returns a `GO` or `GO-WITH-WARNINGS` verdict.

**Do NOT use this sub-skill** for: preflight validation (use `edna-visualize-preflight`); production-scale eDNA classification (use `nf-edna`).

## 0. Inputs / Outputs

### Inputs (consumed from preflight evidence)

| Variable | Source | Description |
| --- | --- | --- |
| `input_asv_counts` | preflight SP1 | ASV-level count table |
| `input_phylum_counts` | preflight SP1 | Phylum-level count table |
| `input_family_counts` | preflight SP1 | Family-level count table |
| `input_genus_counts` | preflight SP1 | Genus-level count table |
| `input_phylum_taxonomy` | preflight SP1 | Phylum-level taxonomy table |
| `input_family_taxonomy` | preflight SP1 | Family-level taxonomy table |
| `input_genus_taxonomy` | preflight SP1 | Genus-level taxonomy table |
| `metadata_file` | preflight SP1 | Sample metadata |
| `output_dir` | preflight SP4 | Output directory |
| `group_by` | preflight SP5 | Optional metadata column for grouping |
| `top_n` | default 50 | Top-N taxa for heatmaps |
| `top_n_taxa` | default 20 | Top-N taxa for stacked bars |
| `preflight_verdict` | preflight verdict file | Must be `GO` or `GO-WITH-WARNINGS` |

### Outputs

- `$OUTPUT_DIR/asv_relabundance.tsv` — normalized ASV-level relative abundance
- `$OUTPUT_DIR/phylum_relabundance.tsv` — Phylum-level relative abundance
- `$OUTPUT_DIR/family_relabundance.tsv` — Family-level relative abundance
- `$OUTPUT_DIR/genus_relabundance.tsv` — Genus-level relative abundance
- `$OUTPUT_DIR/heatmap_phylum.pdf` — CLR heatmap (Phylum)
- `$OUTPUT_DIR/heatmap_family.pdf` — CLR heatmap (Family)
- `$OUTPUT_DIR/heatmap_genus.pdf` — CLR heatmap (Genus)
- `$OUTPUT_DIR/stacked_bar_chart_phylum.pdf` — Stacked bar (Phylum)
- `$OUTPUT_DIR/stacked_bar_chart_family.pdf` — Stacked bar (Family)
- `$OUTPUT_DIR/stacked_bar_chart_genus.pdf` — Stacked bar (Genus)
- `$RUN_DIR/run_summary.json` — compact LLM-loadable summary
- `$RUN_DIR/pipeline_state.json` — run-state file consumed by debug sub-skill (future)

## 0.5 Ask-User Stop Points

Each stop point follows the canonical **Evidence + Recommend + Options** pattern.

---

### SP1 — Preflight verdict confirmed

> **Evidence**: `cat "$RUN_DIR/preflight_verdict.txt"` returns `GO` or `GO-WITH-WARNINGS`.
- ✅ PASS if: verdict is `GO` or `GO-WITH-WARNINGS`
- ❌ FAIL if: verdict is `NO-GO` or file missing

> **Recommend**: PASS → proceed to SP2.
>
> Options:
> - **(A) Preflight is GO, proceed (Recommended)**
> - (B) Re-run preflight (in case inputs changed)
> - (C) Abort

**Auto-pick when**: verdict = `GO` — auto-pick (A). If `GO-WITH-WARNINGS`, surface the warnings to the user and ask before proceeding.

---

### SP2 — Stage 1: normalize counts → relative abundance

> **Evidence**: I will run:
> ```bash
> pixi run --manifest-path env/visualization/pixi.toml \
>   Rscript bin/normalize_abundance.R \
>     --input_asv_counts "$input_asv_counts" \
>     --input_phylum_counts "$input_phylum_counts" \
>     --input_family_counts "$input_family_counts" \
>     --input_genus_counts "$input_genus_counts" \
>     --output_dir "$output_dir"
> ```
- ✅ PASS if: all 4 `*_relabundance.tsv` files created with non-empty content
- ⚠️ WARN if: any file is empty (sample filtering removed all counts)
- ❌ FAIL if: script exited non-zero, or any file missing

> **Recommend**: PASS → proceed to SP3. WARN → confirm. FAIL → re-run with corrected inputs.
>
> Options:
> - **(A) Stage 1 succeeded, proceed to Stage 2 (Recommended)**
> - (B) Stage 1 had warnings; I'm OK with the output
> - (C) Abort

**Auto-pick when**: all 4 TSVs created and non-empty — auto-pick (A).

---

### SP3 — Stage 2: CLR-transformed heatmaps

> **Evidence**: I will run:
> ```bash
> pixi run --manifest-path env/visualization/pixi.toml \
>   Rscript bin/plot_heatmaps.R \
>     --input_phylum_relabund "$output_dir/phylum_relabundance.tsv" \
>     --input_phylum_taxonomy "$input_phylum_taxonomy" \
>     --input_family_relabund "$output_dir/family_relabundance.tsv" \
>     --input_family_taxonomy "$input_family_taxonomy" \
>     --input_genus_relabund "$output_dir/genus_relabundance.tsv" \
>     --input_genus_taxonomy "$input_genus_taxonomy" \
>     --metadata_file "$metadata_file" \
>     --output_dir "$output_dir" \
>     --group_by "$group_by" \
>     --top_n 50
> ```
- ✅ PASS if: 3 `heatmap_*.pdf` files created with non-zero size
- ⚠️ WARN if: any heatmap shows < 3 features (dataset too sparse for top-50)
- ❌ FAIL if: script exited non-zero, or any PDF missing/corrupt

> **Recommend**: PASS → proceed to SP4. WARN → confirm. FAIL → re-run with smaller `--top_n` or check inputs.
>
> Options:
> - **(A) Stage 2 succeeded, proceed to Stage 3 (Recommended)**
> - (B) Re-run with smaller `--top_n 20`
> - (C) Abort

**Auto-pick when**: 3 heatmap PDFs created — auto-pick (A).

---

### SP4 — Stage 3: stacked-bar charts

> **Evidence**: I will run:
> ```bash
> pixi run --manifest-path env/visualization/pixi.toml \
>   Rscript bin/plot_stacked_bar.R \
>     --input_phylum_relabund "$output_dir/phylum_relabundance.tsv" \
>     --input_phylum_taxonomy "$input_phylum_taxonomy" \
>     --input_family_relabund "$output_dir/family_relabundance.tsv" \
>     --input_family_taxonomy "$input_family_taxonomy" \
>     --input_genus_relabund "$output_dir/genus_relabundance.tsv" \
>     --input_genus_taxonomy "$input_genus_taxonomy" \
>     --metadata_file "$metadata_file" \
>     --group_by "$group_by" \
>     --output_dir "$output_dir" \
>     --top_n_taxa 20
> ```
- ✅ PASS if: 3 `stacked_bar_chart_*.pdf` files created
- ⚠️ WARN if: any chart shows only "Other" (dataset has very even distribution; top-20 may not be distinct enough)
- ❌ FAIL if: script exited non-zero, or any PDF missing/corrupt

> **Recommend**: PASS → write `run_summary.json`. WARN → confirm. FAIL → re-run with smaller `--top_n_taxa`.
>
> Options:
> - **(A) Stage 3 succeeded, write run_summary.json (Recommended)**
> - (B) Re-run with `--top_n_taxa 5`
> - (C) Abort

**Auto-pick when**: 3 stacked-bar PDFs created — auto-pick (A).

---

## 1. Run State

After all 4 stop points pass, append to `pipeline_state.json`:

```json
{
  "skill": "eDNA-visualize",
  "version": "1.0.0",
  "completed_stages": ["stage1", "stage2", "stage3"],
  "last_stage": "stage3",
  "verdict": "GO",
  "outputs": {
    "relabundance": ["asv", "phylum", "family", "genus"],
    "heatmaps": ["phylum", "family", "genus"],
    "stacked_bars": ["phylum", "family", "genus"]
  }
}
```

And write `run_summary.json`:

```json
{
  "skill": "eDNA-visualize",
  "version": "1.0.0",
  "run_id": "...",
  "n_samples": 8,
  "n_features_asv": 2719,
  "n_features_phylum": 27,
  "n_features_family": 86,
  "n_features_genus": 234,
  "group_by": null,
  "top_n_heatmap": 50,
  "top_n_stacked_bar": 20,
  "outputs": {
    "relabundance_dir": "$output_dir",
    "heatmaps": ["phylum", "family", "genus"],
    "stacked_bars": ["phylum", "family", "genus"]
  },
  "stage_timings_sec": {"stage1": 10, "stage2": 25, "stage3": 18},
  "completed_at": "2026-08-19T18:00:00Z"
}
```

## 2. Troubleshooting — Signature library

| Signature in stderr / log | Likely cause | Suggested fix |
| --- | --- | --- |
| `cutadapt: adapter not found` | (n/a — this skill does not run cutadapt) | n/a |
| `Error: No common samples between relative abundance table and metadata` | Sample-ID mismatch (should have been caught by preflight SP2) | Re-run preflight; fix sample-ID alignment in input tables |
| `Error in library(sechm) : there is no package called 'sechm'` | sechm not in pixi env | `pixi add --manifest-path env/visualization/pixi.toml bioconductor-sechm` |
| `Error in plotAbundance: 'rank' must be a column in rowData(tse)` | Taxonomy table missing the expected rank column | Verify taxonomy table has a column matching the level name (`Phylum` / `Family` / `Genus`) |
| `PDF device: cannot open file` | Output directory not writable | Re-run preflight SP4 to identify a writable output dir |
| `Rscript: command not found` | pixi env not activated | Re-invoke `pixi run --manifest-path env/visualization/pixi.toml ...` instead of bare `Rscript` |
| `Heatmap is empty (no features passed the top_n filter)` | `--top_n` is too small for the dataset | Re-run with `--top_n 100` (default 50); or check that count table is not empty |
| `Stacked bar shows only "Other" (no top-N taxa)` | All taxa are below `--top_n_taxa` threshold (dataset has very even distribution) | Re-run with `--top_n_taxa 5` (default 20); or check that count table is not uniform |
| `Error: gpar(fontsize = 8)` from ComplexHeatmap | ComplexHeatmap version incompatible with sechm | Update both: `pixi run --manifest-path env/visualization/pixi.toml R -e 'BiocManager::install("ComplexHeatmap"); BiocManager::install("sechm")'` |

## 3. Related skills

- **`eDNA-visualize`** (parent) — invokes this sub-skill from SP0
- **`preflight/edna-visualize-preflight`** (prerequisite) — must pass verdict before this sub-skill runs
- **`nf-edna`** — upstream: produces the 4 count tables + 3 taxonomy tables
- **`idtaxa-training`** — sibling: produces the classifier that generated the classifications being visualized

## Verification

- [ ] `preflight_verdict.txt` was `GO` or `GO-WITH-WARNINGS` before any stage script was constructed (SP1).
- [ ] The exact `pixi run Rscript ...` command for each stage was shown to the user and explicitly confirmed (Step invariant).
- [ ] `pipeline_state.json.completed_stages` was extended only after a stage succeeded (Step invariant).
- [ ] All 4 normalized TSVs + 3 heatmap PDFs + 3 stacked-bar PDFs are written.
- [ ] `run_summary.json` was written at the end of the run.

## Invariants

- **Never** run a stage script without showing the full command first and waiting for explicit confirmation.
- **Never** modify a successfully-written artifact (`*_relabundance.tsv`, `*.pdf`).
- **Never** skip the preflight sub-skill — its verdict gates this sub-skill.