# nf-edna

A Nextflow DSL2 pipeline for eDNA metabarcoding analysis, covering QC, denoising, taxonomic classification, diversity, and association stages for four marker genes: **16S** (Bacteria/Archaea), **18S-V9**, **COI**, and **12S** (Eukaryota).

A single pipeline codebase handles all four markers — marker-specific behavior (amplicon length range, kingdom filter, taxonomic ranks, optional geographic curation) is supplied via `-params-file` presets rather than separate pipeline copies.

## Stages

| Stage | Module | What it does |
|---|---|---|
| QC | `modules/qc.nf` | Primer trimming (cutadapt), FastQC |
| Denoise | `modules/denoise.nf` | Pair merging (NGmerge), ASV inference (VSEARCH UNOISE3), decontamination, negative-control filtering |
| Classify | `modules/classify.nf` | IDTAXA taxonomic classification, confidence filtering, rank agglomeration, optional geocuration |
| Diversity | `modules/diversity.nf` | Phylogenetic tree, alpha diversity, beta diversity (PERMANOVA, community typing) |
| Association | `modules/association.nf` | Differential abundance, taxon-environment and taxon-taxon correlation |

Each stage can be run incrementally via named Nextflow entry points (`QC_ONLY`, `DENOISE_ONLY`, `CLASSIFY_ONLY`, `DIVERSITY_ONLY`, or the default workflow for all stages including association), with `-resume` reusing cached work from prior stages.

## Running

```bash
nextflow run nf-edna \
  -params-file nf-edna/params/{16s|18s-v9|coi|12s}.json \
  -params-file path/to/run-specific-params.json \
  -resume
```

`-params-file` flags merge left-to-right (last wins) — always pass the marker preset first, then run-specific overrides (manifest, metadata, IDTAXA model, run ID, etc.) second.

To run only through a given stage:

```bash
nextflow run nf-edna -entry CLASSIFY_ONLY -params-file ... -params-file ...
```

## Marker presets (`params/`)

| Preset | Marker | Length range | Kingdoms | DAA/correlation level | Geocurate |
|---|---|---|---|---|---|
| `16s.json` | 16S | 350–550 bp | Bacteria, Archaea | Genus | off |
| `18s-v9.json` | 18S-V9 | 100–180 bp | Eukaryota | Species | off |
| `coi.json` | COI | 290–340 bp | Eukaryota | Species | on |
| `12s.json` | 12S | 150–200 bp | Eukaryota | Species | on |

Reference assets (trained IDTAXA models, taxonomy tables) live under `assets/{16s,18s-v9,coi,12s}/` and are gitignored — supply your own per `.gitignore`'s tracked patterns.

## Post-processing for AI interpretation

`bin/summarise_run.py` consolidates a completed run's outputs (read flow, ASV counts, taxonomy, top taxa, alpha/beta diversity, differential abundance, correlations, blank QC warnings) into a single compact `run_summary.json`, avoiding the need to load large raw tables into an LLM's context window:

```bash
python3 nf-edna/bin/summarise_run.py \
  --results_dir analyses/{analysis_id}/results \
  --run_id {run_id}
```

## Agentic workflow skills

This pipeline ships with three Claude Code skills (`.claude/skills/edna-intake.md`, `edna-run.md`, `edna-interpret.md`) that drive intake, execution, and interpretation of runs through an AI agent. They're plain Markdown with YAML frontmatter (`name:` / `description:` + free-text instructions) — there is nothing Claude-Code-specific in their content, so they can be imported into other agentic coding tools that support markdown-based skill/instruction files (e.g. Codex, OpenCode), typically by pointing the tool at the file or copying it into that tool's own skill-discovery directory and asking it to import the skill. Verify against the target tool's own skill format/frontmatter conventions before relying on it verbatim.

- `edna-intake.md` — elicit run parameters, validate inputs, write the initial `pipeline_state.json`
- `edna-run.md` — execute pipeline stages, monitor progress, update `pipeline_state.json`
- `edna-interpret.md` — turn outputs into a structured report, narrative summary, and interactive Q&A
