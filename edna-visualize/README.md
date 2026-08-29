# Sub-Skill: eDNA-visualize

Publication-ready figure generation for **environmental DNA (eDNA) metabarcoding** analysis. Bridges the gap between agglomerated count tables and journal-quality figures.

## What it does

Three end-to-end stages for generating publication-ready eDNA figures:

1. **Counts → relative abundance** via `bin/normalize_abundance.R`
   - Takes 4 count tables (ASV / Phylum / Family / Genus)
   - Uses `mia::transformAssay(method = "relabundance")`
   - Writes 4 normalized TSVs
2. **CLR-transformed heatmaps** via `bin/plot_heatmaps.R`
   - Builds `TreeSummarizedExperiment` from relabundance + taxonomy + metadata
   - `mia::transformAssay(method = "clr")` + `standardize` (row-wise z-score)
   - `sechm()` / `ComplexHeatmap` heatmaps at Phylum / Family / Genus levels
   - Optional `--group_by` for averaging replicates
3. **High-contrast stacked bars** via `bin/plot_stacked_bar.R`
   - Lumps rare taxa (below `--top_n_taxa` threshold) to "Other"
   - `miaViz::plotAbundance()` stacked bars at Phylum / Family / Genus levels
   - High-contrast palette (30 colors) for taxonomic diversity

## When to use

Use `eDNA-visualize` when you need to:

- Normalize raw ASV counts to relative abundance at Phylum / Family / Genus levels
- Generate CLR-transformed heatmaps showing community composition across samples
- Generate stacked-bar charts with the top-N taxa displayed individually and the rest lumped as "Other"
- Produce publication-ready figures for a 16S / 18S-V9 / COI / 12S eDNA dataset

Do NOT use this skill for raw FASTQ processing (use `read-qc-trimming` then `nf-edna`), or for statistical analyses (use `nf-edna`).

## Where it fits

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

## Quick start

```bash
# 1. Preflight — validates all 8 input tables + mia/sechm packages
invoke_skill preflight/edna-visualize-preflight

# 2. Run — stages 1-3
invoke_skill run/edna-visualize-run

# Outputs (in $output_dir):
#   *_relabundance.tsv        — 4 normalized count tables (ASV/Phylum/Family/Genus)
#   heatmap_*.pdf             — 3 CLR-transformed heatmaps
#   stacked_bar_chart_*.pdf   — 3 stacked-bar charts
#   run_summary.json          — compact LLM-loadable summary
```

## Structure

```
eDNA-visualize/
├── SKILL.md                                   # Router
├── README.md                                  # Human guide
└── pixi.toml                                  # Agent runtime deps
├── bin/
│   ├── normalize_abundance.R                  # Stage 1: counts → relabundance
│   ├── plot_heatmaps.R                        # Stage 2: CLR heatmaps
│   └── plot_stacked_bar.R                     # Stage 3: stacked bars
├── preflight/
│   └── edna-visualize-preflight/SKILL.md      # 5 stop points + verdict gate
└── run/
    └── edna-visualize-run/SKILL.md            # 4 stop points + state writes
```

## Example usage

```bash
# With an nf-edna output directory containing:
#   results/run_id/classify/asv_counts.tsv
#   results/run_id/classify/phylum_counts.tsv + phylum_taxonomy.tsv
#   results/run_id/classify/family_counts.tsv + family_taxonomy.tsv
#   results/run_id/classify/genus_counts.tsv + genus_taxonomy.tsv
#   run/metadata.tsv

OUTPUT_DIR=/home/user/figures
pixi run --manifest-path env/visualization/pixi.toml \
  Rscript bin/normalize_abundance.R \
    --input_asv_counts results/run_id/classify/asv_counts.tsv \
    --input_phylum_counts results/run_id/classify/phylum_counts.tsv \
    --input_family_counts results/run_id/classify/family_counts.tsv \
    --input_genus_counts results/run_id/classify/genus_counts.tsv \
    --output_dir "$OUTPUT_DIR"

pixi run --manifest-path env/visualization/pixi.toml \
  Rscript bin/plot_heatmaps.R \
    --input_phylum_relabund "$OUTPUT_DIR/phylum_relabundance.tsv" \
    --input_phylum_taxonomy results/run_id/classify/phylum_taxonomy.tsv \
    --input_family_relabund "$OUTPUT_DIR/family_relabundance.tsv" \
    --input_family_taxonomy results/run_id/classify/family_taxonomy.tsv \
    --input_genus_relabund "$OUTPUT_DIR/genus_relabundance.tsv" \
    --input_genus_taxonomy results/run_id/classify/genus_taxonomy.tsv \
    --metadata_file run/metadata.tsv \
    --output_dir "$OUTPUT_DIR" \
    --top_n 50

pixi run --manifest-path env/visualization/pixi.toml \
  Rscript bin/plot_stacked_bar.R \
    --input_phylum_relabund "$OUTPUT_DIR/phylum_relabundance.tsv" \
    --input_phylum_taxonomy results/run_id/classify/phylum_taxonomy.tsv \
    --input_family_relabund "$OUTPUT_DIR/family_relabundance.tsv" \
    --input_family_taxonomy results/run_id/classify/family_taxonomy.tsv \
    --input_genus_relabund "$OUTPUT_DIR/genus_relabundance.tsv" \
    --input_genus_taxonomy results/run_id/classify/genus_taxonomy.tsv \
    --metadata_file run/metadata.tsv \
    --output_dir "$OUTPUT_DIR" \
    --top_n_taxa 20
```

## Related skills

- **nf-edna** (`~/.pi/agent/skills/nf-edna/`) — upstream: produces the 4 count tables + 3 taxonomy tables via `classify.nf:agglomerate_data`
- **idtaxa-training** (`~/.pi/agent/skills/idtaxa-training/`) — sibling: produces the classifier that generated the classifications being visualized
- **read-qc-trimming** (`~/.pi/agent/skills/read-qc-trimming/`) — upstream: pre-processes raw reads
- **html-template-pack** (`~/.pi/agent/skills/html-template-pack/`) — downstream: package figures into a reviewable HTML report

## Version

v1.0.0 — initial release (2026-08-19)

## Author

AIx-BIO (`cheahhl814`)