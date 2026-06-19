# nf-edna-agent

A Nextflow DSL2 pipeline for eDNA metabarcoding analysis, covering QC, denoising, taxonomic classification, diversity, and association stages for four marker genes: **16S** (Bacteria/Archaea), **18S-V9**, **COI**, and **12S** (Eukaryota) — paired with AI agent skills (see [Agentic workflow skills](#agentic-workflow-skills)) that drive intake, execution, and interpretation of runs.

A single pipeline codebase handles all four markers — marker-specific behavior (amplicon length range, kingdom filter, taxonomic ranks, optional geographic curation) is supplied via `-params-file` presets rather than separate pipeline copies.

The pipeline itself lives under [`nf-edna/`](nf-edna/); all relative paths below are within that directory unless noted otherwise.

## Prerequisites

- [Nextflow](https://www.nextflow.io/) (DSL2-compatible release)
- [Pixi](https://pixi.sh/) — manages the per-stage tool environments under `nf-edna/env/` (cutadapt, NGmerge, VSEARCH, R/Bioconductor packages, Julia) and the Julia environment used by `nf-edna/bin/decontam.jl` and related scripts. Each process invokes its tools via `pixi run --manifest-path env/{stage}/pixi.toml ...`; Pixi resolves and caches these environments on first use — no manual `conda`/`mamba` setup required.
- Reference assets per marker (trained IDTAXA models, taxonomy tables) — see below.

## Stages

| Stage       | Module                   | What it does                                                                                         |
| ----------- | ------------------------ | ---------------------------------------------------------------------------------------------------- |
| QC          | `nf-edna/modules/qc.nf`          | Primer trimming (cutadapt), FastQC                                                                   |
| Denoise     | `nf-edna/modules/denoise.nf`     | Pair merging (NGmerge), ASV inference (VSEARCH UNOISE3), decontamination, negative-control filtering |
| Classify    | `nf-edna/modules/classify.nf`    | IDTAXA taxonomic classification, confidence filtering, rank agglomeration, optional geocuration      |
| Diversity   | `nf-edna/modules/diversity.nf`   | Phylogenetic tree, alpha diversity, beta diversity (PERMANOVA, community typing)                     |
| Association | `nf-edna/modules/association.nf` | Differential abundance, taxon-environment and taxon-taxon correlation                                |

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

## Marker presets (`nf-edna/params/`)

| Preset        | Marker | Length range | Kingdoms          | DAA/correlation level | Geocurate |
| ------------- | ------ | ------------ | ----------------- | --------------------- | --------- |
| `16s.json`    | 16S    | 350–550 bp   | Bacteria, Archaea | Genus                 | off       |
| `18s-v9.json` | 18S-V9 | 100–180 bp   | Eukaryota         | Species               | off       |
| `coi.json`    | COI    | 290–340 bp   | Eukaryota         | Species               | on        |
| `12s.json`    | 12S    | 150–200 bp   | Eukaryota         | Species               | on        |

Reference assets (trained IDTAXA models, taxonomy tables) live under `nf-edna/assets/{16s,18s-v9,coi,12s}/` and are gitignored — supply your own per `.gitignore`'s tracked patterns.

## Post-processing for AI interpretation

`nf-edna/bin/summarise_run.py` consolidates a completed run's outputs (read flow, ASV counts, taxonomy, top taxa, alpha/beta diversity, differential abundance, correlations, blank QC warnings) into a single compact `run_summary.json`, avoiding the need to load large raw tables into an LLM's context window:

```bash
python3 nf-edna/bin/summarise_run.py \
  --results_dir analyses/{analysis_id}/results \
  --run_id {run_id}
```

## Agentic workflow skills

This pipeline ships with three Claude Code skills (`.claude/skills/edna-intake.md`, `edna-run.md`, `edna-interpret.md`) that drive intake, execution, and interpretation of runs through an AI agent. They're plain Markdown with YAML frontmatter (`name:` / `description:` + free-text instructions) — there is nothing Claude-Code-specific in their content, so they can be imported into other agentic coding tools that support markdown-based skill/instruction files (e.g. Codex, Gemini CLI, OpenCode, Pi). Verify against the target tool's own skill format/frontmatter conventions before relying on it verbatim.

- `edna-intake.md` — elicit run parameters, validate inputs, write the initial `pipeline_state.json`
- `edna-run.md` — execute pipeline stages, monitor progress, update `pipeline_state.json`
- `edna-interpret.md` — turn outputs into a structured report, narrative summary, and interactive Q&A

### Example prompts

In Claude Code, the skills are invoked as slash commands (`/edna:intake`, `/edna:run`, `/edna:interpret`); in other agentic tools, invoke them however that tool triggers an imported skill (by name, or by referencing the instructions file directly).

**Starting a new run:**

> `/edna:intake`
>
> "I have a new 16S run, sample data in `raw_reads/siteA/`, metadata at `metadata/siteA.tsv`. Primers are the standard 515F/806R pair."

**Continuing an in-progress run:**

> `/edna:run`
>
> "Continue run `16s-20260521-siteA` — run all remaining stages."

**Running only through a specific stage:**

> `/edna:run`
>
> "For run `12s-20260601-reef3`, just run through classification — I want to check taxonomy before committing to diversity/association."

**Retrying after a failure:**

> "The QC stage failed on run `coi-20260603-bay2` — primer not found. Retry with `--primer_mismatch_rate 0.2`."

**Interpreting completed results:**

> `/edna:interpret`
>
> "Interpret run `16s-20260521-siteA` and write the report."

**Follow-up Q&A after a report is written:**

> "Which taxa are driving the separation between the site clusters?"
>
> "Is the low read count in sample siteA-03 something I should worry about?"
>
> "Summarize this for a manuscript Results section, focused on the dominant phyla."

### Importing into other agentic tools

For tools with native skill/instruction-file support (e.g. Codex, Gemini CLI), point the tool at the file and ask it to import the skill — or copy it into that tool's own skill-discovery directory first if it only auto-loads from a fixed location. A prompt along these lines works for most tools:

> "Import the skill defined in `.claude/skills/edna-intake.md` (and `edna-run.md`, `edna-interpret.md`) in this repo as one of your own skills/custom instructions. Keep the `name` and `description` frontmatter, and follow the body instructions verbatim when invoked."

For tools without native skill support, paste the file's contents directly into a custom instructions/system-prompt mechanism, or reference the file path in your prompt each time you want that workflow followed.
