---
name: edna-run
description: "Execute the correct eDNA metabarcoding stage(s) for the run's marker preset — agent-driven: the agent constructs the stage's tool commands from the canonical recipe table, shows them to the scientist, executes them under the per-stage pixi environments, and updates pipeline_state.json only after verified success. Stages: qc (cutadapt + FastQC), denoise (NGmerge + VSEARCH UNOISE3 + decontam + negative-control filter), classify (DECIPHER IDTAXA + confidence filter + agglomeration + optional geocuration), diversity (mafft + FastTree + alpha + beta/PERMANOVA + community typing), association (differential abundance + correlations). Refuses to execute when the upstream preflight/edna-intake verdict is NO-GO. Has 4 explicit ask-user stop points (SP1–SP4). Triggers: 'run eDNA pipeline', 'execute eDNA stages', 'continue eDNA run', 'eDNA QC stage', 'eDNA denoise', 'eDNA classify', 'eDNA diversity', 'eDNA association'."
version: 1.2.0
updated: "2026-10-08"
triggers:
  - "run eDNA pipeline"
  - "execute eDNA stages"
  - "continue eDNA run"
  - "eDNA QC stage"
  - "eDNA denoise"
  - "eDNA classify"
  - "eDNA diversity"
  - "eDNA association"
---

# edna-run

> **v1.2.0.** Agent-driven only. The `nextflow run` command-construction steps were replaced by the canonical **stage recipe tables** below: each recipe is the exact tool invocation validated on real data (2026-08-19 NF 24 + 2026-10-07 agent-driven rounds). Marker preset + run params are merged into ONE JSON at intake; recipes read merged parameters directly. New signature-library entries from the round-2 battle-test: missing env dependencies (NGmerge), mia↔rbiom pin, empty `--num_clusters`, rank case sensitivity, kingdoms vs mitochondrial superkingdom.

## Audience

- **AI Coding Agents** — read `pipeline_state.json`, enforce the verdict gate (SP1), determine the next stage, construct commands from the recipe tables, show them to the scientist, execute under `pixi run --manifest-path env/{stage}/pixi.toml …`, and update state only after verified success.
- **Human eDNA scientists** — use the recipe tables to run stages manually.

## When to Use This Skill

- **Continue** a run whose `pipeline_state.json` exists (verdict ≥ `GO-WITH-WARNINGS`).
- Run one or more stages (`qc`, `denoise`, `classify`, `diversity`, `association`) with the correct tool chain.
- **Resume**: every stage is idempotent; rerun safely after fixing a parameter.

## Do NOT use this skill

- If there is **no `pipeline_state.json`** → invoke `preflight/edna-intake` first (SP1 refuses without it).
- If the intake verdict is **`NO-GO`** → fix the failing evidence item first.
- If results are **complete and classified** and you only want reporting → `interpret/edna-interpret`.

## 0. Inputs / Outputs contract

### Inputs (consumed)

| Path | Source | Required? | Notes |
| --- | --- | --- | --- |
| `results/{run_id}/pipeline_state.json` | `preflight/edna-intake` | yes | Verdict ∈ {GO, GO-WITH-WARNINGS} gates all execution |
| `results/{run_id}/params.json` | `preflight/edna-intake` | yes | Preset + run-specific values **merged into one JSON at intake** |
| `params/{marker}.json` | skill-bundled preset | yes (input to the intake merge) | Marker-specific lengths/kingdoms/levels |

### Outputs (produced)

| Path | Owner | Notes |
| --- | --- | --- |
| `results/{run_id}/qc/trimmed/<sample>/` | this skill | cutadapt primer-trimmed FASTQs |
| `results/{run_id}/qc/fastqc/<sample>/` | this skill | FastQC reports (raw + trimmed) |
| `results/{run_id}/denoise/` | this skill | merged reads + per-sample ASVs |
| `results/{run_id}/asv_table/` | this skill | merged table, decontam + filter outputs |
| `results/{run_id}/taxonomy/` | this skill | IDTAXA outputs + `agglomerated_data/` rank tables |
| `results/{run_id}/diversity/` | this skill | tree + alpha + beta + community typing |
| `results/{run_id}/association/` | this skill | DAA + correlations |
| `results/{run_id}/pipeline_state.json` | updated | completed_stages/last_stage only after verified success |
| `results/{run_id}/run_summary.json` | `bin/summarise_run.py` | written when association completes |

### Verdict gate enforcement

Before constructing any command, read `pipeline_state.json.verdict`. `NO-GO`/missing → SP1 (refuse). `GO-WITH-WARNINGS` → one confirmation prompt before Step 3.

## 0.5 Ask-User Stop Points

### SP1 — Verdict gate fails

| Trigger | Action |
| --- | --- |
| `pipeline_state.json` missing / `verdict: NO-GO` / missing verdict | Hard-stop: "I see no `pipeline_state.json` for run `{run_id}` (or verdict is `NO-GO`). Invoke `preflight/edna-intake` first." |
| `verdict == GO-WITH-WARNINGS` | Ask: "Verdict is `GO-WITH-WARNINGS` (`<items>`). Pick: (A) continue anyway, (B) re-run intake, (C) abort". Auto-pick: `verdict == GO`. |

### SP2 — Pipeline-state schema mismatch

`pipeline != "edna-agent"` OR `marker ∉ {16s, 18s-v9, coi, 12s}` → ask: "(A) unrelated run — give correct run_id, (B) typo — I fix it, (C) abort". Auto-pick: `pipeline ∈ {"edna-agent", "nf-edna"}` — v1.1.x-era state files carry `pipeline: "nf-edna"` and remain valid inputs (the stage recipes are unchanged).

### SP3 — Stage failure choice

A stage command exits non-zero → Ask: "`<stage>` failed with `<excerpt>`. Pick: (A) **retry** — adjust a merged param (tell me which) and rerun, (B) **skip** this stage (recorded in the report; never added to completed_stages), (C) **abort** (state preserved)". Auto-pick when the stage succeeds: no ask.

### SP4 — Resume-from-stage ambiguity

`completed_stages` ≥ 2 entries AND user did not specify → Ask: "I see `<N>` stages complete. Pick: (A) only the **next** stage, (B) **all remaining** stages, (C) a specific stage". Auto-pick (≤1 entry + "continue"): next stage only.

### Operating rule

> **Auto-pick when the evidence is unambiguous; ask when the agent genuinely cannot decide.** Evidence + Recommend + Options.

## Description

You are the pipeline execution agent. Read the current `pipeline_state.json`, determine what to run next, show the exact commands, execute after confirmation, verify outputs, and update state.

## Stage ladder

| `last_stage`  | Next stage |
|---------------|------------|
| `intake`      | `qc` |
| `qc`          | `denoise` |
| `denoise`     | `classify` |
| `classify`    | `diversity` |
| `diversity`   | `association` |
| `association` | complete → `bin/summarise_run.py` → `interpret/edna-interpret` |

## Procedure

### Step 1 — Locate the run

Read `results/{run_id}/pipeline_state.json`. Enforce SP1. Auto-detect schema (SP2).

### Step 2 — Determine the next stage

From `last_stage` / `completed_stages` via the stage ladder. SP4 fires if ambiguous.

### Step 3 — Construct the commands from the recipe tables

Variables (from merged params.json): `$S` = sample-id column set of the manifest; `$P` = merged params; per stage `ENV[stage] = pixi run --manifest-path <skill-root>/env/<stage>/pixi.toml`. Show every command (Step 4 invariant) before running.

#### Stage `qc` — primer trim (cutadapt) + FastQC

For each sample `sid` with raw R1/R2:

```bash
ENV[qc] cutadapt --error-rate 0.1 --times 1 --overlap 3 --minimum-length ${P.min_length} \
  -j ${N_CPU} -g ${P.primers_fwd} -G ${P.primers_rev} --discard-untrimmed \
  -o results/${RUN_ID}/qc/trimmed/${sid}/${sid}_R1.trimmed.fastq.gz \
  -p results/${RUN_ID}/qc/trimmed/${sid}/${sid}_R2.trimmed.fastq.gz \
  ${r1} ${r2}

ENV[qc] fastqc -t ${N_CPU} -q -o results/${RUN_ID}/qc/fastqc/${sid} ${r1} ${r2} <trimmed R1> <trimmed R2>
```

Notes: `--maximum-length` is intentionally NOT passed — for short amplicons (MiFish 12S, ~170 bp on 251 bp MiSeq reads) read-through produces ~225 bp merged-length reads and a length cap would kill them pre-merge (v1.1.0 battle-test Finding 2). Verify: every sample dir has both trimmed FASTQs, non-empty; capture cutadapt's retention per sample.

#### Stage `denoise` — merge + UNOISE3 + decontam + filter

Per sample, from the trimmed pair:

```bash
ENV[denoise] NGmerge -1 <R1.trimmed> -2 <R2.trimmed> -o results/${RUN_ID}/denoise/${sid}.merged.fastq.gz -z
ENV[denoise] vsearch --fastx_uniques ${sid}.merged.fastq.gz --fastaout ${sid}.derep.fasta --sizeout --minuniquesize 2 --fastq_ascii 33
ENV[denoise] vsearch --cluster_unoise ${sid}.derep.fasta --centroids ${sid}.sequences.fasta --biomout ${sid}.table.biom --minsize 2 --unoise_alpha 2.0
ENV[denoise] biom convert -i ${sid}.table.biom -o ${sid}.table.tsv --to-tsv \
  || printf '# Constructed from biom file\n#OTU ID\t%s\n' "${sid}" > ${sid}.table.tsv
```

Then the merge/decontam chain once, after all samples:

```bash
ENV[denoise] Rscript bin/merge_tables.R --input_files <all *.table.tsv> --output_table feature-table.tsv
awk 'BEGIN{FS=OFS="\t"} {gsub(/:/,"_",$1); print}' feature-table.tsv > feature-table_renamed.tsv
cat <all *.sequences.fasta> > rep-seqs.fna; sed '/^>/s/:/_/g' rep-seqs.fna > rep-seqs_renamed.fna

ENV[decontam] julia bin/decontam.jl --feature_table feature-table_renamed.tsv \
  --metadata ${P.metadata} --rep_seqs rep-seqs_renamed.fna \
  --output_cleaned_table asv_table/decontam_asv_table.tsv --output_cleaned_rep_seqs asv_table/decontam_rep_seqs.fna \
  --output_contaminants_summary asv_table/decontam_summary.tsv \
  --threshold ${P.decontam_threshold} --neg_control_column ${P.neg_col}

ENV[decontam] julia bin/filter_table.jl --feature_table asv_table/decontam_asv_table.tsv \
  --rep_seqs asv_table/decontam_rep_seqs.fna --metadata ${P.metadata} \
  --filter_condition "is_negative == false" \
  --output_table asv_table/filtered_asv_table.tsv --output_rep_seqs asv_table/filtered_rep_seqs.fna
```

Notes: (1) FIRST USE of the decontam env requires its Julia deps: `ENV[decontam] julia -e 'using Pkg; Pkg.instantiate()'` — run once if ArgParse is missing; (2) empty per-sample tables ARE expected (samples with no ASVs are skipped by merge_tables.R with a warning); (3) the julia filter accepts QIIME2-style TRUE/FALSE strings.

#### Stage `classify` — IDTAXA + confidence filter + agglomeration

```bash
sed 's/;size=[0-9]*//' asv_table/filtered_rep_seqs.fna > taxonomy/rep_seqs_clean.fna

ENV[classification] Rscript bin/idtaxa_rds.R --query_sequences taxonomy/rep_seqs_clean.fna \
  --idtaxa_model ${P.idtaxa_model} \
  --output_classification taxonomy/idtaxa_classification.tsv \
  --output_confidence taxonomy/idtaxa_confidence.tsv

ENV[decontam] julia bin/filter_idtaxa_by_confidence.jl \
  --classification_file taxonomy/idtaxa_classification.tsv --confidence_file taxonomy/idtaxa_confidence.tsv \
  --output_file taxonomy/idtaxa_classification_confident.tsv --threshold ${P.idtaxa_threshold}

ENV[classification] Rscript bin/agglomerate_data.R \
  --asv_counts_file asv_table/filtered_asv_table.tsv \
  --taxonomy_file taxonomy/idtaxa_classification_confident.tsv \
  --metadata_file ${P.metadata} --output_dir taxonomy/agglomerated_data \
  --kingdoms ${P.kingdoms} --ranks ${P.target_ranks}

tail -n +2 taxonomy/agglomerated_data/asv_counts.tsv | awk '{print $1}' > taxonomy/asv_ids_to_keep.txt
sed 's/;size=[0-9]*//' asv_table/filtered_rep_seqs.fna > taxonomy/rep_seqs_clean.fna   # (idempotent)
ENV[classification] seqtk subseq taxonomy/rep_seqs_clean.fna taxonomy/asv_ids_to_keep.txt > taxonomy/filtered_asvs.fna
```

Notes: (1) `bin/idtaxa_rds.R` loads standard RDS, gzipped RDS, and XZ/RDX3 DECIPHER trainingFiles automatically; (2) `--kingdoms` filtering happens inside agglomerate — for **mitochondrial markers (12S/COI) the superkingdom is `unassigned`**, so the preset ships `kingdoms: "all"` (pass anything else and ALL ASVs are dropped); (3) pass rank levels in the exact case used by the taxonomy columns (`genus`, `species`).

#### Stage `diversity` — tree + alpha + beta + community typing

```bash
mkdir -p diversity/phylogenetic_tree diversity/alpha diversity/beta
ENV[diversity] mafft --thread ${N_CPU} --auto taxonomy/filtered_asvs.fna > diversity/phylogenetic_tree/aligned-rep-seqs.fna
ENV[diversity] fasttree -nt -gtr diversity/phylogenetic_tree/aligned-rep-seqs.fna > diversity/phylogenetic_tree/unrooted-tree.nwk
ENV[diversity] Rscript bin/root_tree.R --input_tree diversity/phylogenetic_tree/unrooted-tree.nwk \
  --output_tree diversity/phylogenetic_tree/rooted-tree.nwk

ENV[diversity] Rscript bin/alpha_diversity.R --input_asv_counts taxonomy/agglomerated_data/asv_counts.tsv \
  --input_metadata ${P.metadata} --input_tree diversity/phylogenetic_tree/rooted-tree.nwk \
  --grouping_variable "${P.grouping_variable}" --output_dir diversity/alpha

ENV[diversity] Rscript bin/beta_diversity.R --input_asv_counts taxonomy/agglomerated_data/asv_counts.tsv \
  --input_asv_taxonomy taxonomy/agglomerated_data/asv_taxonomy.tsv --input_metadata ${P.metadata} \
  --input_tree diversity/phylogenetic_tree/rooted-tree.nwk \
  --grouping_variable "${P.grouping_variable}" --distance_metric "${P.distance_metric:-bray}" \
  --output_dir diversity/beta

ENV[diversity] Rscript bin/community_typing.R --input_asv_counts taxonomy/agglomerated_data/asv_counts.tsv \
  --input_metadata ${P.metadata} --clustering_method "${P.clustering_method:-ward.D2}" \
  --output_dir diversity/beta        # do NOT pass --num_clusters with an empty string
```

#### Stage `association` — differential abundance + correlations

```bash
mkdir -p association/differential_abundance association/correlation

ENV[association] Rscript bin/differential_abundance.R \
  --input_asv_counts taxonomy/agglomerated_data/asv_counts.tsv \
  --input_asv_taxonomy taxonomy/agglomerated_data/asv_taxonomy.tsv \
  --input_metadata ${P.metadata} --output_dir association/differential_abundance \
  --level_to_analyze "genus" --fixed_effect_variable "${P.grouping_variable}" \
  --top_n_taxa_plot ${P.top_n_taxa_plot:-20} --reference_level "${P.reference_level}"
# NOTE: rank is matched case-insensitively by correlation_analysis.R but case-SENSITIVELY
# by differential_abundance.R — pass lowercase ("genus"/"species") until fixed upstream.

cp association/differential_abundance/Maaslin2_all_results.tsv \
   association/differential_abundance/differential_abundance_results.tsv

ENV[association] Rscript bin/correlation_analysis.R \
  --input_asv_counts taxonomy/agglomerated_data/asv_counts.tsv \
  --input_asv_taxonomy taxonomy/agglomerated_data/asv_taxonomy.tsv \
  --input_metadata ${P.metadata} --input_alpha_diversity diversity/alpha/alpha_diversity_metrics.tsv \
  --fixed_effect_variable "${P.grouping_variable}" --metadata_numeric_variables "${P.metadata_numeric_variables}" \
  --level_to_analyze "Genus" --output_dir association/correlation/correlation_analysis_genus
ENV[association] Rscript bin/correlation_analysis.R  ...same... --level_to_analyze "Family" \
  --output_dir association/correlation/correlation_analysis_family
```

### Step 4 — Show commands and wait for confirmation

Display the full command chain and ask: "Proceed? (yes / no / change a parameter)". If a parameter changes, update `results/{run_id}/params.json` (the intake-merged file), re-merge if the preset base changed, and show revised commands. Do not execute until confirmed.

### Step 5 — Execute and verify

Run each stage's commands (Bash tool). After each stage, verify outputs BEFORE updating state — per stage:

| Stage | Verify |
| --- | --- |
| qc | every sample dir has `*_R1/_R2.trimmed.fastq.gz` non-empty; record cutadapt retention % |
| denoise | `asv_table/filtered_asv_table.tsv` + `filtered_rep_seqs.fna` exist non-trivial |
| classify | `taxonomy/agglomerated_data/asv_counts.tsv` has ≥ 1 sample column |
| diversity | `diversity/alpha/alpha_diversity_metrics.tsv` + `diversity/beta/permanova_results.tsv` exist |
| association | `association/differential_abundance/differential_abundance_results.tsv` exists |

Report progress: "✓ QC complete (retention 93%)"; "✓ DENOISE complete (2,719 ASVs / 7 samples)".

### Step 6 — Handle failures (SP3)

Extract the failing command's stderr (kept under `results/{run_id}/<stage>_run.log`), explain the cause in plain language (signature library below), present the three options. Never update state on failure.

### Step 7 — Update state on success

Extend `completed_stages`, set `last_stage`, append output paths to `outputs` in `pipeline_state.json`. Never on failure.

### Step 8 — Generate the run summary

When `association` completes (or the scientist stops early after `classify`):

```bash
python3 bin/summarise_run.py --results_dir results --run_id ${RUN_ID} --manifest <manifest.csv>
```

Writes `results/{run_id}/run_summary.json` (read-flow incl. raw counts, blank QC, ASV counts, taxonomy rates, top taxa, diversity, DAA, correlations).

NOTE for runs with a changed marker classification: summariser reads canonical names (`taxonomy/idtaxa_classification_confident.tsv`, `taxonomy/agglomerated_data/…`, `association/differential_abundance/differential_abundance_results.tsv`). If you used non-canonical names, reconcile them (copy/rename) before summarising.

### Step 9 — Hand off

> "Pipeline complete through `{last_stage}`. Completed: {completed_stages}. Run summary: `results/{run_id}/run_summary.json`. To interpret: `interpret/edna-interpret`."

## Marker-sanity check (run between DENOISE and CLASSIFY — strongly recommended)

The round-2 battle-test's central real-data lesson: primer sites being present on reads (96%) does NOT prove the amplicon is the intended marker (0/2,719 ASVs matched the intended 12S reference). Before running `classify`, run a cheap sanity classification of a small ASV sample against the intended marker's reference:

```bash
head -1000 taxonomy/rep_seqs_clean.fna > /tmp/sanity_asvs.fna      # ~200 ASVs
ENV[denoise] vsearch --usearch_global /tmp/sanity_asvs.fna \
  --db ${MARKER_REFERENCE} --id 0.80 --query_cov 0.8 --target_cov 0.6 \
  --userout /tmp/sanity_hits.tsv --userfields query+target+id
# 0 hits → WARN loudly before CLASSIFY: "marker assumption may be wrong" (ask user; see SKILL.md F10)
```

If the marker reference is unsuited to the primer pair (e.g., reference amplicons don't span the primer sites), the check itself reports 0 and the correct response is to **re-source or re-train the reference** (chain `reference-db/` → `idtaxa-training/`) — treat "0 sanity hits" as evidence for either a wrong marker OR an unsuitable reference, and ask the scientist which.

## Troubleshooting — Signature library

| Signature in stderr / log | Likely cause | Suggested fix |
| --- | --- | --- |
| `NGmerge: command not found` | denoise pixi env missing NGmerge (v1.1.5 regression, fixed v1.2.0) | `pixi add --manifest-path env/denoise/pixi.toml ngmerge` |
| `cutadapt: adapter not found in reads` | wrong primer or orientation | check primer vs publication; loosen `--error-rate 0.15`; confirm marker via post-denoise sanity check |
| `NGmerge: paired reads failed merge` | insert < 30 bp or SE data | check manifest read type |
| `VSEARCH: no reads survive dereplication` | min_length too strict or empty upstream | lower min_length 20–30 bp; check cutadapt log |
| `biom convert: file is empty / can't be parsed` | sample had 0 ASVs after UNOISE3 | expected — the `|| printf header` fallback writes a header-only TSV; merge_tables.R skips it with a warning |
| `Package ArgParse is required but does not seem to be installed` (Julia) | decontam env not instantiated | `pixi run --manifest-path env/decontam/pixi.toml julia -e 'using Pkg; Pkg.instantiate()'` |
| `parse(Bool, "FALSE")` style Julia failure | QIIME2 TRUE/FALSE strings in Bool columns | v1.2.0 filter_table.jl handles case-insensitively (fix verified 2026-08-19) |
| `Incompatible join types: logical vs character` (R) | empty per-sample table merged | v1.2.0 merge_tables.R skips empty tables (verified) |
| `object 'unifrac' is not exported by 'namespace:rbiom'` | mia 1.18 + rbiom 3.x incompatibility | pin `r-rbiom ==2.2.1` in env/{classification,diversity,association}; keep the opportunistic mia-load guards in the R scripts |
| `could not find function "TreeSummarizedExperiment"` | mia loads via requireNamespace but TSE attach skipped | explicit `library(TreeSummarizedExperiment)` (present in v1.2.0 scripts) |
| `rank matches a name at the wrong level` / `unexpected Parent` / `rank is missing the name` (LearnTaxa) | taxonomy-header defects: same taxon name at multiple ranks; shared gap-placeholder with inconsistent parents; binomial-split phantom genus when species' binomial genus ≠ header genus | lineage-uniquify header placeholders; prefer `LearnTaxa(seqs, groups)` (rank=NULL) on lineage-cleaned headers; or regenerate the reference FASTA via `idtaxa-training`'s prepare script with per-level placeholders |
| `LearnTaxa` silently dies / exit 137 | OOM — DECIPHER training memory scales with total reference bases (full mitogenomes blow up) | train on in-silico-amplicon-length sequences; 1 record per unique species path; ~6-9k seqs fits a 14 GB box |
| Classification output all-NA despite plausible model | `IdTaxa` default threshold (60, on 0–100 scale) + confidence's length dependence on short queries | pass `threshold` explicitly; compare query vs training length regime; prefer training sequences of similar length (in-silico amplicons) |
| `PERMANOVA R2 = 1.0` with no F/p | one sample per group — degenerate model | expected with unreplicated grouping variables; report as such |
| no DAA power (0/n significant) | reference level absent from counts (negatives pre-filtered), or 1 sample/group | pick a replicable reference_level at intake; SP: confirm |
| `argument --num_clusters: invalid int value: ''` | pipeline default empty string passed as CLI arg | omit the flag (script auto-determines); never pass empty string |
| `Taxonomic rank 'Genus' not found` (DAA) | case-sensitive rank match in differential_abundance.R (columns are lowercase) | pass lowercase ("genus"); upstream fix: case-insensitive match as in correlation_analysis.R |
| `Removed 2719 ASVs with unassigned Kingdom. Remaining: 0` | kingdoms preset incompatible with mitochondrial references | use `kingdoms: "all"` for 12S/COI (preset fixed v1.2.0) |
| summariser `AttributeError: NoneType … get` | section None in summary dict | guard fixed in v1.2.0 bin/summarise_run.py; rerun |
| disk full in env resolution | per-stage pixi env resolution 1–3 GB | ≥ 10 GB free at results/ (E7) |

## Verification

- [ ] `pipeline_state.json.verdict` was GO / GO-WITH-WARNINGS before any command (SP1)
- [ ] The exact commands were shown to the scientist and confirmed (Step 4 invariant)
- [ ] `completed_stages` extended only after verified outputs (Step 5 verify table)
- [ ] `last_stage == association` → `run_summary.json` generated (Step 8)
- [ ] Marker-sanity check ran (or was consciously skipped with a reason recorded)

## Invariants

- **Never** execute without showing the commands first.
- **Never** update `pipeline_state.json` for a failed stage.
- **Never** pass an empty string to numeric CLI args.
- **Never** use capitalized rank arguments with `differential_abundance.R` until its match is case-insensitive.
- **Always** merge preset + run params into one JSON at intake (single-`--params-file` era lesson, now simply single-file).
- **Always** run the marker-sanity check unless the scientist explicitly declines (record the decline).