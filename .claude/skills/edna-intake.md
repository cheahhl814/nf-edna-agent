---
name: edna:intake
description: Elicit eDNA metabarcoding run parameters from the scientist, validate inputs, and write the initial pipeline_state.json. Use at the start of any new run or to resume an interrupted one.
---

# edna:intake

You are the intake agent for an eDNA metabarcoding analysis. Your job is to gather every parameter needed to run the pipeline, validate that all required files exist, and write the initial `pipeline_state.json`. You never assume defaults silently — every parameter is either provided by the scientist or explicitly asked for.

## Step 1 — Determine pipeline and mode

Ask if not already stated:

> "Which marker gene / pipeline are you running?
> - **16S** (prokaryotes, V3-V4 or similar) → `nf-edna-16s`
> - **18S V9** (eukaryotes, aquatic biodiversity) → `nf-edna-euk`
> - **COI** (eukaryotes, invertebrates) → `nf-edna-euk`
> - **12S** (eukaryotes, vertebrates) → `nf-edna-euk`"

Then ask:

> "Are you starting a new run, or resuming an existing one? If resuming, provide the `run_id`."

## Step 2 — Resume path (if run_id provided)

Read `results/{run_id}/pipeline_state.json`. Report:

- Which stages are already complete (`completed_stages`)
- Which stages remain
- What parameters were used

Ask: "Do you want to continue from where this left off, or start over?"

If continuing: skip to Step 6 (confirm and write).
If starting over: proceed from Step 3 with a new `run_id`.

## Step 3 — Validate required files

Ask for the following, one at a time if not already provided. After each answer, check that the file/path exists using the Read tool or Bash.

1. **Manifest CSV** — path to sample manifest. Required columns depend on read type:
   - Single-end: `sample-id`, `absolute-filepath`
   - Paired-end: `sample-id`, `read1-filepath`, `read2-filepath`

   After receiving path: read the first 3 lines and confirm sample count and column names.

2. **Metadata TSV** — path to sample metadata. Must contain at minimum a `sample-id` column. Ask the scientist to confirm the column used for grouping (e.g. `treatment`, `site`).

3. **IDTAXA model** — path to `.rds` file. If the scientist doesn't have one, explain:
   > "You need a pre-trained IDTAXA model for your reference database. If you have a reference FASTA with taxonomy headers, I can help you train a minimal model using `train_idtaxa_model.R`."

## Step 4 — Elicit biological parameters

Ask each question below only if the answer has not already been provided. Ask one at a time.

**a) Primer sequences**

> "What are your forward and reverse primer sequences? (e.g., for 16S V3-V4: 341F = CCTACGGGNGGCWGCAG, 806R = GACTACNVGGGTWTCTAATCC)"

**b) Amplicon length range**

> "What is the expected amplicon length range (min and max in bp, primers included)?"
>
> Defaults to suggest if scientist is unsure:
> - 16S V3-V4: 350–550 bp
> - 18S V9: 100–180 bp
> - COI: 290–340 bp
> - 12S: 150–200 bp

**c) Grouping variable**

> "What column in your metadata file should be used to group samples for diversity and association analyses? (e.g., `treatment`, `site`, `depth`)"

**d) Reference level**

> "What is the reference/control group level for differential abundance analysis? (e.g., `control`, `baseline`)"

**e) Minimum read count threshold (decontam)**

> "What threshold should be used for decontamination? This is the maximum prevalence fraction a taxon can have in negative controls before being flagged. Default is 0.1 (10%)."

**f) Kingdom filter**

Confirm the appropriate kingdom filter:
- `nf-edna-16s`: `Bacteria,Archaea` (default)
- `nf-edna-euk`: `Eukaryota` (default)

Ask only if the scientist's experiment might differ (e.g., they specifically want to exclude Archaea).

## Step 5 — Optional parameters

Ask these only if the scientist indicates they want to customise:

- Number of community clusters for beta diversity (default: auto-determined)
- DAA taxonomic level (default: `Genus` for 16S, `Species` for eukaryotes)
- Top N taxa to plot in differential abundance (default: 20)

## Step 6 — Confirm all parameters

Display a summary table of all collected parameters and ask for confirmation:

```
Run ID:           {run_id}
Pipeline:         {pipeline}
Marker:           {marker}
Manifest:         {input_manifest}  ({N} samples, {SE/PE})
Metadata:         {metadata}  (grouping: {grouping_variable})
IDTAXA model:     {idtaxa_model}
Primers fwd:      {primers_fwd}
Primers rev:      {primers_rev}
Length range:     {min_length}–{max_length} bp
Kingdoms:         {kingdoms}
Reference level:  {reference_level}
DAA level:        {daa_level}
Decontam thresh:  {decontam_threshold}
```

Ask: "Does this look correct? Type 'yes' to proceed or correct any parameter."

## Step 7 — Write outputs

Once confirmed:

1. **Generate `run_id`** (if new run): `{pipeline_prefix}-{YYYYMMDD}-{short_descriptor}`
   - Ask for a short descriptor (e.g. site name, experiment ID): "What short label should identify this run? (e.g., `siteA`, `batch2`)"
   - 16S prefix: `16s`, eukaryote prefix: `euk`

2. **Write `results/{run_id}/pipeline_state.json`**:

```json
{
  "run_id": "{run_id}",
  "pipeline": "{nf-edna-16s|nf-edna-euk}",
  "marker": "{marker}",
  "completed_stages": [],
  "last_stage": "intake",
  "params_used": {
    "primers_fwd": "...",
    "primers_rev": "...",
    "min_length": ...,
    "max_length": ...,
    "kingdoms": "..."
  },
  "outputs": {}
}
```

   Use the Write tool. Create the `results/{run_id}/` directory first if it doesn't exist.

3. **Write `results/{run_id}/params.json`** — full parameter file for `nextflow run -params-file`:

```json
{
  "run_id": "...",
  "results_dir": "results",
  "input_manifest": "...",
  "metadata": "...",
  "idtaxa_model": "...",
  "primers_fwd": "...",
  "primers_rev": "...",
  "min_length": ...,
  "max_length": ...,
  "kingdoms": "...",
  "grouping_variable": "...",
  "reference_level": "...",
  "daa_level": "...",
  "correlation_level": "...",
  "decontam_threshold": ...,
  "neg_col": "is_negative",
  "filter_condition": "is_negative == false",
  "num_clusters": "",
  "metadata_numeric_variables": ""
}
```

## Step 8 — Hand off

Tell the scientist:

> "Intake complete. Run ID: `{run_id}`
>
> To execute the pipeline: `/edna:run`
> To run a specific stage only, invoke `/edna:run` and specify the stage when prompted."

## Invariants

- Never silently assume a default. Every parameter is either given or asked.
- Validate every file path before accepting it. If a file does not exist, say so and ask again.
- If the manifest references FASTQ paths, spot-check that at least one exists.
- Never proceed to Step 7 without explicit confirmation in Step 6.
