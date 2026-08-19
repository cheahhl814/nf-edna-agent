---
name: edna-interpret
description: "Turn nf-edna pipeline outputs into a structured Markdown report and deep dive navigation plan, a plain-language narrative summary, and an interactive Q&A session. Refuses to interpret if upstream pipeline_state.json.completed_stages lacks 'classify'. Has 4 explicit ask-user stop points (SP1–SP4) that fire only when evidence is ambiguous. Triggers: 'interpret eDNA results', 'eDNA report', 'summarize eDNA run', 'eDNA Results section', 'eDNA diversity interpretation', 'eDNA differential abundance'."
version: 1.1.1
updated: "2026-08-19"
triggers:
  - "interpret eDNA results"
  - "eDNA report"
  - "summarize eDNA run"
  - "eDNA Results section"
  - "eDNA diversity interpretation"
  - "eDNA differential abundance"
---

# edna-interpret

> **v1.1.0.** Adds the canonical BettaMt structure (§0 Inputs/Outputs contract, §0.5 Ask-User Stop Points with Evidence + Recommend + Options, §Troubleshooting — Signature library). The procedure body (Steps 1–5 below) is unchanged from v1.0.0 — only the structured wrappers were added. The Step 2b anomaly check has been formalized as SP2.

## Audience

This skill serves two simultaneous audiences:

- **AI Coding Agents** — triggered by the phrases above. The agent must read `pipeline_state.json.completed_stages` and enforce the gate (SP1), run the anomaly scan (SP2), and write `<run_id>-report.md` grounded in real data from `run_summary.json` — never invent findings.
- **Human eDNA scientists** — read this document as a workflow guide. The `## When to Use` / `## Do NOT use` sections explain *why* classification must complete first, *why* anomaly flags are surfaced before report-writing (not buried in Caveats), and *why* the Q&A answers must be grounded in the actual files for this run.

## When to Use This Skill

Use this skill when you need to:

- **Interpret a completed eDNA run** (classification stage has run, optionally diversity + association too).
- **Generate a structured `<run_id>-report.md`** with Run Summary, QC, ASV & Taxonomy, Diversity, DAA, Correlation, and Caveats sections.
- **Generate a plain-language narrative** suitable for a manuscript Results-section draft.
- **Enter an interactive Q&A session** with the scientist about the run's findings.

## Do NOT use this skill

- If `pipeline_state.json.completed_stages` does **not** contain `classify` (SP1 hard-stop). The report cannot be written without classified ASVs.
- If you only want to **look at raw output files** without interpretation — use `Read` / `Bash` directly.
- If you want to **re-run the pipeline** — invoke `run/edna-run` instead.
- If the run is still **in progress** — wait for the pipeline to reach `last_stage: association` (or at minimum `last_stage: classify`).

## 0. Inputs / Outputs contract

### Inputs (consumed)

| Path | Source | Required? | Notes |
| --- | --- | --- | --- |
| `results/{run_id}/pipeline_state.json` | `run/edna-run` | yes | `completed_stages` must include `classify` (SP1 gate). Used for `run_id`, `marker`, `params_used`, `outputs`. |
| `results/{run_id}/run_summary.json` | `bin/summarise_run.py` (invoked by `run/edna-run`) | yes | The compact LLM-loadable summary. Provides `read_flow`, `blank_qc`, `asv_counts`, `taxonomy`, `top_taxa`, `alpha_diversity`, `beta_diversity`, `differential_abundance`, `correlations`, `notes`. |
| `results/{run_id}/{stage}_output/...` | Nextflow pipeline | conditional | Read on-demand for detail not captured in the summary (full ASV lists, raw correlation tables, individual PDFs). |

### Outputs (produced)

| Path | Format | Owner | Notes |
| --- | --- | --- | --- |
| `results/{run_id}/{run_id}-report.md` | Markdown | this skill | The structured report (Step 3). Sections: Run Summary, QC Summary, ASV & Taxonomy Overview, Alpha Diversity, Beta Diversity, Differential Abundance, Correlation Analysis, Caveats. |
| `results/{run_id}/narrative.md` | Markdown | this skill | A 2–3 paragraph plain-language summary suitable for a manuscript Results-section draft (Step 4). |
| (no on-disk output for Q&A) | conversation | this skill | Q&A answers are given in-line; the scientist's questions are not persisted unless the user asks for a transcript (Step 5). |

### Verdict gate enforcement

Before reading any output, **read `pipeline_state.json.completed_stages`**. If `classify` is not present → SP1 fires (refuse to proceed; suggest running `run/edna-run` to completion).

## 0.5 Ask-User Stop Points

This sub-skill has **4 stop points** (SP1–SP4). Each fires only when the evidence is ambiguous. The format is **Evidence + Recommend + Options**.

### SP1 — Stage-completeness gate

| Trigger | Evidence check | Action |
| --- | --- | --- |
| `pipeline_state.json.completed_stages` lacks `classify` | Required stage missing | Hard-stop: "Classification has not run yet for this run (`completed_stages` = `<list>`). I can only interpret results from the classify stage onwards. Run `run/edna-run` to complete classification first, or I can describe what the QC/denoising outputs show so far — would you like that?" |

**Auto-pick when**: `classify ∈ completed_stages`. No ask.

### SP2 — Anomaly severity

| Trigger | Evidence check | Action |
| --- | --- | --- |
| One or more anomalies found in Step 2b scan: zero ASVs, empty taxonomy, low confidence-filter retention, blank contamination, missing expected output files, very low read counts, no decontam filtering despite contaminated blanks | The report would mislead if these are silently buried in Caveats | Ask: "I detected `<N>` anomalies before writing the report (listed below). Pick: (A) **proceed** with interpretation, surfacing each anomaly prominently in Caveats (recommended), (B) **investigate first** — tell me which anomaly to dig into, (C) **abort** until upstream stages re-run\n\nAnomalies:\n- `<list>`" |

**Auto-pick when**: zero anomalies detected. No ask.

### SP3 — Report-scope ambiguity

| Trigger | Evidence check | Action |
| --- | --- | --- |
| `completed_stages` contains `classify` but not `diversity` and not `association`; OR scientist asks "summarize what we have so far" mid-pipeline | Partial run; not all sections can be written | Ask: "Run is partially complete (`<list>`). Pick: (A) write the report sections for the stages that exist and mark the missing stages as 'Output unavailable' in each section (recommended), (B) write only the QC + ASV/Taxonomy sections (skip Diversity/DAA/Correlation), (C) wait until more stages complete" |

**Auto-pick when**: `diversity ∈ completed_stages` AND `association ∈ completed_stages` (full run). No ask.

### SP4 — Q&A termination

| Trigger | Evidence check | Action |
| --- | --- | --- |
| Scientist signals completion ("thanks", "done", "exit", or no follow-up for ≥ 3 turns) | The session has reached its natural end | No ask needed for the response itself, but: when the Q&A mode terminates, **ask** one final clarification: "Before I close this interpretation session: pick (A) **save the Q&A transcript** to `results/{run_id}/qa_transcript.md`, (B) **discard** the transcript, (C) keep the report as-is and add the transcript inline to the report" |

**Auto-pick when**: scientist is mid-Q&A. No ask (the Q&A itself is the conversation).

### Operating rule

> **Auto-pick when the evidence is unambiguous; ask when the agent genuinely cannot decide.** When asking, present the evidence first, then the recommendation, then 2–4 concrete options. Do not ask "what do you want?" — ask "I see X, recommend Y, which one of A/B/C?"

## Description

You are the interpretation agent for an eDNA metabarcoding analysis. You turn pipeline output files into scientific understanding — a structured report and deep dive navigation plan, a narrative summary suitable for a draft Results section, and an interactive Q&A session where the scientist can ask follow-up questions.

## Prerequisites

- **Environment**: pixi env with `python ≥ 3.10` (for `bin/summarise_run.py` if not already generated).
- **Upstream evidence**: `results/{run_id}/pipeline_state.json` with `classify ∈ completed_stages` (SP1), and `results/{run_id}/run_summary.json` (generated by `run/edna-run` Step 8 when `association` completes, or on-demand by this skill).
- **User-provided inputs**: `run_id`.

## Procedure

### Step 1 — Locate the run + enforce gate (SP1)

Ask if not already stated:

> "What is the `run_id` for the run you want to interpret?"

Read `results/{run_id}/pipeline_state.json`. **Enforce SP1**: `classify` must be in `completed_stages`. If only `qc` or `denoise` is complete:

> "Classification has not run yet for this run. I can only interpret results from the classify stage onwards. Run `run/edna-run` to complete classification first, or I can describe what the QC/denoising outputs show so far — would you like that?"

### Step 2 — Load run summary

Check for `results/{run_id}/run_summary.json`. If it exists, read it — it is the primary data source for all subsequent steps and avoids re-reading every individual output file.

If it does not exist, generate it:

```bash
python3 bin/summarise_run.py \
  --results_dir results \
  --run_id {run_id}
```

The summary provides: `read_flow`, `blank_qc`, `asv_counts`, `taxonomy` (classification rates, kingdom distribution, read loss, confidence filter stats), `top_taxa` (top 10 at each agglomeration rank), `alpha_diversity`, `beta_diversity` (PERMANOVA + cluster assignments), `differential_abundance`, `correlations`, and `notes`.

Fall back to reading individual output files only for detail not captured in the summary (e.g., full ASV lists, raw correlation tables beyond top 10).

### Step 2b — Anomaly scan (before writing the report; SP2 trigger)

Before writing anything, scan for anomalies. Use `run_summary.json` where possible. If any are found, **SP2 fires** (ask user before proceeding) — do NOT silently bury anomalies in Caveats:

- **Zero ASVs**: `asv_counts.raw` = 0 in summary, or `asv_table/feature-table_renamed.tsv` is empty
- **Empty taxonomy**: `taxonomy.total_asvs` = 0 in summary, or `taxonomy/idtaxa_classification_confident.tsv` has no classified sequences
- **Missing expected output files**: for each path listed in `pipeline_state.json` `outputs`, check that the file exists on disk using the actual `results/{run_id}/` directory. The stored paths in `outputs` may be stale (pointing to a different machine's home directory) — do not trust them literally; verify by navigating relative to the current results directory instead.
- **Very low read counts**: any sample with < 100 trimmed reads in `read_flow` (exclude blank samples)
- **Blank contamination**: check `blank_qc` in `run_summary.json`. If the list is non-empty, a blank sample has more reads than one or more biological samples — flag this prominently. Decontam may not catch reagent contaminants that co-occur in biological samples. Also check `asv_counts.contaminants_flagged` — if 0 despite contaminated blanks, flag for human review.
- **No decontam filtering despite contaminated blanks**: if `asv_table/decontam_summary.tsv` exists, check whether any ASVs with high prevalence in negative controls (> 30%) and zero prevalence in true samples were NOT flagged as contaminants — this may indicate overly permissive decontam thresholds.
- **Low confidence-filter retention**: if `taxonomy.confidence_filter.pct_lost` > 20%, a significant fraction of ASVs failed confidence thresholds — note this in Caveats.

### Step 3 — Mode 1: Structured report

Write `results/{run_id}/{run_id}-report.md` with the following sections. Read each relevant output file before writing its section.

### Run Summary

From `pipeline_state.json` (`params_used` field — there is no separate `params.json` file):

- Pipeline and marker gene
- Run ID
- Parameters used (primers, length range, kingdoms)
- Number of samples (count directories in `asv_table/per_sample/`, excluding blanks)
- Completed stages

### QC Summary

Use `read_flow` from `run_summary.json` for trimmed read counts per sample. If `raw` values are present, compute retention rate; if absent, note that raw counts require re-running `summarise_run.py --manifest <path>`.

If `run_summary.json` is unavailable, count reads from `qc/trimmed/` directly:
```bash
zcat qc/trimmed/{sample}/{sample}.trimmed.fastq.gz | wc -l
# divide by 4
```

Report:

- Trimmed read counts per sample (exclude blank samples)
- Blank read counts and any blank_qc warnings from `run_summary.json`
- Any samples with notably low post-trimming counts (< 1,000 reads)
- Number of samples that passed trimming

### ASV and Taxonomy Overview

From `run_summary.json`:
- `asv_counts`: raw → decontam → filtered progression; `contaminants_flagged`
- `taxonomy.total_asvs`, `taxonomy.kingdom_distribution`, `taxonomy.classification_rates` (% classified per rank)
- `taxonomy.confidence_filter`: ASVs lost to confidence filtering (if any)
- `taxonomy.read_loss_to_kingdom_filter`: reads lost after excluding non-target kingdoms
- `top_taxa`: top 10 taxa by total reads at each available agglomeration rank (phylum/class/family/genus). Use these directly — do not re-sum the count tables unless you need finer detail.

Available ranks vary by pipeline: 16S runs typically have phylum/family/genus; eukaryote (V9) runs typically have class/family/genus. The `top_taxa` object in the summary contains only ranks that were actually produced.

Report:
- ASV counts at each stage with % retained
- Number of unique taxa at each available rank (row counts from `taxonomy/agglomerated_data/*_counts.tsv` if not in summary)
- Top 5 most abundant taxa at the finest available rank from `top_taxa`
- Dominant kingdom/phylum/class composition

Note: IDTAXA may skip intermediate ranks — a taxon classified at "class" level may appear in the `class` column even if it is biologically a phylum. Do not assume rank columns always correspond to the standard biological rank of the name.

### Alpha Diversity

From `diversity/alpha/alpha_diversity_metrics.tsv`:

- Key metrics present (columns in the file; typically: Observed, Shannon, Faith's PD)
- Range and mean across samples (exclude blanks by sample name)
- Notable patterns: are groups different? Are any samples outliers?

If diversity stage did not run: note this section is unavailable.

### Beta Diversity

From `run_summary.json` `beta_diversity`:
- `permanova`: PERMANOVA results per dissimilarity metric (R², F, p-value). These come from `diversity/beta/permanova_results.tsv`, which is published.
- `community_typing`: per-sample cluster assignments from `diversity/beta/sample_clusters.tsv`, which is published and readable as a plain TSV (columns: `SampleID`, `Cluster`).
- `available_outputs`: list of PDF files present

PDF files (cannot be read directly — describe by filename):
- `pcoa_bray_curtis.pdf` — Bray-Curtis dissimilarity PCoA (composition + abundance)
- `pcoa_aitchison.pdf` — Aitchison distance PCoA (log-ratio, compositional)
- `pcoa_jaccard.pdf` — Jaccard dissimilarity PCoA (presence/absence)
- `heatmap_bray_curtis.pdf` — sample-by-sample dissimilarity heatmap
- `community_typing_plots.pdf` — cluster assignments visualised

Report PERMANOVA R² and p-values per metric, and which cluster each sample belongs to. If all samples cluster together (single cluster), flag this — it may indicate insufficient group structure or too few samples.

Note: `community_typing.rds` is a binary R object not directly readable. Use `sample_clusters.tsv` instead for cluster assignments.

If diversity stage did not run: note this section is unavailable.

### Differential Abundance

From `association/differential_abundance/differential_abundance_results.tsv`:

- Number of significantly differentially abundant taxa (rows where `qval` < 0.05)
- Top taxa by effect size (`coef` column, absolute value)
- Direction of enrichment per group (`value` column shows which group is enriched)
- The metadata variable tested (`metadata` column — this is the grouping variable used in the analysis)

If association stage did not run: note this section is unavailable.

### Correlation Analysis

From `association/correlation/` — check which rank subdirectories are present (e.g. `correlation_analysis_genus/`, `correlation_analysis_family/`). For each:

**Taxon–environment correlations** (`feature_metadata_correlations_{rank}.tsv`):

- Columns: Feature, Metadata_Variable, Correlation, P_value, Q_value
- Report the top 5 strongest significant correlations (Q_value < 0.05) between taxa and environmental variables
- Note which environmental variables were tested

**Taxon–taxon co-occurrence** (`feature_feature_correlations_{rank}.tsv`):

- Report notable significant co-occurrence or mutual exclusion pairs (Q_value < 0.05, excluding self-correlations)
- Limit to top 5 strongest pairs

Heatmap PDFs in this directory show the same data visually — list them by filename.

If association stage did not run: note this section is unavailable.

### Caveats

List any anomalies flagged in SP2, plus:

- Stages that did not run
- Whether `asv_table/decontam_summary.tsv` exists; if absent, note that decontam details are unavailable and only ASV count difference can be reported
- Blank contamination: if `blank_qc` in `run_summary.json` is non-empty, note which blank samples had more reads than biological samples and that downstream diversity/association results may be confounded
- Any taxa that could not be classified below a high rank: use `taxonomy.classification_rates` — any rank with < 50% classified warrants mention
- IDTAXA confidence filter: if `taxonomy.confidence_filter.pct_lost` > 0, report ASVs lost and note the confidence threshold used
- Agglomerated ranks that were expected but absent (e.g. species-level for eukaryote runs)
- Raw read counts unavailable: if `read_flow` shows no `raw` values, note that pre-trimming counts were not captured and the manifest path should be supplied to `summarise_run.py`
- Any R/statistical warnings visible in association output

---

Marker-aware interpretation guidelines:

**16S runs:**

- Higher diversity expected (hundreds to thousands of ASVs)
- Interpret at genus level (finest typically available)
- Frame dominant taxa in functional guild terms: nitrifiers, sulfate reducers, fermenters, phototrophs
- Note if Archaea are present and their proportion

**Eukaryote runs (18S-V9 / COI / 12S):**

- Lower ASV counts expected (tens to low hundreds for V9)
- Interpret at species level if `species_counts.tsv` exists; otherwise use the finest available rank (typically genus or class)
- Frame dominant taxa in ecological guild terms: predator/prey, trophic level, habitat indicator
- Note if any invasive or indicator species appear

---

After writing all sections, confirm to the scientist:

> "Report written to `results/{run_id}/{run_id}-report.md`."

### Step 4 — Mode 2: Narrative summary

Write a 2–3 paragraph plain-language summary of the findings, suitable for a draft Results section of a scientific paper. Append it to `results/{run_id}/{run_id}-report.md` under a `## Narrative Summary` heading and also print it to the terminal.

The narrative should:

- State what was sequenced, how many samples, and what marker gene
- Summarise the key biological findings (dominant taxa, diversity patterns, significant associations)
- Mention any important caveats or limitations
- Use past tense, passive voice where conventional ("reads were trimmed", "ASVs were classified")
- Avoid pipeline-specific jargon (say "amplicon variants" not "ASVs" if writing for a general audience)

### Step 5 — Mode 3: Interactive Q&A

After the report is written, enter Q&A mode:

> "The report is complete. Ask me any follow-up questions about the results — for example:
> 
> - Which taxa drive the separation between groups?
> - Is the low read count in sample X a problem?
> - What functional roles do the dominant taxa likely have?
> - Are there any taxa that suggest contamination?
> - Which environmental variables correlate most strongly with community composition?"

For each question:

1. Identify which output file(s) are relevant
2. Read those files
3. Answer based on actual data, not assumptions
4. If the answer requires a file that is missing or empty, say so explicitly

Stay in Q&A mode until the scientist signals they are done (e.g., "thanks", "done", "exit") — at which point SP4 fires (Q&A termination ask).

## Troubleshooting — Signature library

| Signature in stderr / log | Likely cause | Suggested fix |
| --- | --- | --- |
| `run_summary.json missing` | `bin/summarise_run.py` was not invoked at the end of `run/edna-run` (Stage 8 was skipped) | Run `python3 bin/summarise_run.py --results_dir results --run_id {run_id}` first, then re-invoke `interpret/edna-interpret` |
| `top_taxa table is empty at finest rank` | All ASVs were filtered out at that agglomeration rank (low confidence, or low prevalence) | Fall back to the next coarser rank (genus → family → class → phylum); mention the fallback in Caveats |
| `taxonomy.classification_rates: 0% at species rank` (eukaryote run) | IDTAXA confidence threshold dropped all species-level assignments | Note in Caveats; interpret at genus level instead. For 16S, species-level is rarely expected — this is normal. |
| `blank_qc is non-empty but asv_counts.contaminants_flagged == 0` | Decontam ran but found no flaggable contaminants (either blanks are below the prevalence threshold, or the threshold is too permissive) | Flag in Caveats; suggest re-running with `--decontam_threshold 0.05` (more aggressive) and reviewing `decontam_summary.tsv` manually |
| `community_typing.rds is a binary R object; cannot read directly` | The summariser left the raw R object instead of the TSV | Use `diversity/beta/sample_clusters.tsv` (the published companion); if missing, regenerate with `Rscript bin/community_typing.R` |
| `IDTAXA confidence filter lost > 20% ASVs` (`pct_lost > 20`) | The confidence threshold (default 60) is too stringent for this reference DB | Note in Caveats; do not silently drop the section. Optionally re-run classification with `--idtaxa_confidence 50` (more permissive). |
| `expected output files missing (e.g., pcoa_bray_curtis.pdf)` | Diversity or association stage did not run, or crashed mid-output | Check `pipeline_state.json.completed_stages`; if missing, invoke `run/edna-run` to complete those stages |
| `Outputs paths in pipeline_state.json point to a different machine's home directory` | State file was generated on a different machine and rsynced | Do NOT trust the `outputs` paths literally; navigate relative to the current `results/{run_id}/` instead |
| `Q&A answer requires a file that doesn't exist or is empty` | The scientist asked about an output that was never produced | Say so explicitly; do not invent findings. Offer to re-run the relevant pipeline stage. |

## Verification

- [ ] `results/{run_id}/{run_id}-report.md` exists with all 8 sections (Run Summary, QC, ASV/Taxonomy, Alpha Diversity, Beta Diversity, DAA, Correlation, Caveats).
- [ ] Every reported number in the report can be traced to `run_summary.json` or a specific output file in `results/{run_id}/`.
- [ ] Every anomaly flagged in SP2 is mentioned in the Caveats section.
- [ ] The narrative summary is appended under `## Narrative Summary` heading.
- [ ] If Q&A mode ran, the transcript (if saved per SP4) is at `results/{run_id}/qa_transcript.md`.

## Invariants

- Never write a report section based on assumed data. Read the actual output files.
- If an expected output file is missing or empty, flag it as a Caveats item and do not silently skip the section — write "Output unavailable: {reason}" in that section.
- Never claim a taxon was detected without reading the taxonomy file.
- Do not assume which agglomerated rank files exist — always list the directory first.
- The Q&A answers must be grounded in the actual files for this run. Do not speculate beyond what the data shows.
- **Never** interpret before the SP1 stage-completeness gate has passed.