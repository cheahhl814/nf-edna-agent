---
name: edna-intake
description: "Validate eDNA metabarcoding run inputs and write the initial pipeline_state.json with a GO / GO-WITH-WARNINGS / NO-GO verdict. Mirrors the bettamt-preflight pattern (gather inputs → compute evidence → write the machine contract). Computes 6 evidence items (marker, manifest schema, sample-count parity, metadata completeness, IDTAXA model, disk + tool availability) and refuses to write a GO verdict if any required tool or input is missing. The downstream run/edna-run sub-skill refuses to execute without verdict ≥ GO-WITH-WARNINGS. Has 7 explicit ask-user stop points (SP1–SP7) that fire only when evidence is ambiguous. Triggers: 'new eDNA run', 'start eDNA run', 'eDNA intake', 'resume eDNA run', 'eDNA pipeline parameters', 'marker gene 16S 18S COI 12S', 'set up eDNA metabarcoding'."
version: 1.1.3
updated: "2026-08-19"
triggers:
  - "new eDNA run"
  - "start eDNA run"
  - "eDNA intake"
  - "resume eDNA run"
  - "eDNA pipeline parameters"
  - "marker gene 16S 18S COI 12S"
  - "set up eDNA metabarcoding"
---

# edna-intake

> **v1.1.0.** Adds the canonical BettaMt / `bettamt-preflight` structure (§0 Inputs/Outputs contract, §0.5 Ask-User Stop Points with Evidence + Recommend + Options, §Troubleshooting — Signature library, GO / GO-WITH-WARNINGS / NO-GO verdict gate). The procedure body (Steps 1–8 below) is unchanged from v1.0.0 — only the structured wrappers were added. Mirrors `bioinfo-skill-creator/preflight/skill-creator-preflight/SKILL.md`.

## Audience

This skill serves two simultaneous audiences:

- **AI Coding Agents** — triggered by the phrases above. The agent must run all six evidence collection steps (marker, manifest schema, sample-count parity, metadata completeness, IDTAXA model, disk + tool availability), then write `pipeline_state.json` with the `verdict` field set. `run/edna-run` will refuse to execute if `verdict < GO-WITH-WARNINGS`.
- **Human eDNA scientists** — read this document as a workflow guide. The `## When to Use` / `## Do NOT use` sections and the `## Invariants` list at the bottom explain *why* each step exists and what guarantees the intake makes.

## When to Use This Skill

Use this skill when you need to:

- Start a **new eDNA metabarcoding run** for one of the four supported markers (16S, 18S-V9, COI, 12S).
- **Resume** an interrupted run (the skill detects `pipeline_state.json` and offers continue-vs-restart).
- Validate that all input files (manifest, metadata, IDTAXA model, FASTQ paths) exist and have the expected schema **before** committing compute to a Nextflow run.
- Get a machine-readable `pipeline_state.json` that `run/edna-run` reads without re-deriving choices.

## Do NOT use this skill

- If you have **raw reads that have not been QC-trimmed yet** — run `read-qc-trimming` first. nf-edna's `qc` stage does primer trimming; if your reads also need adapter trimming + quality filtering, do that first.
- If you want to **run the pipeline immediately** — this skill only writes the intake state; invoke `run/edna-run` after.
- If your marker is **not one of the four supported** (16S, 18S-V9, COI, 12S) — the marker-specific behavior is hardcoded across `modules/` and `bin/` scripts. Adding a new marker requires a pipeline extension (out of scope for v1.1.0).
- If you want to **interpret already-completed results** — invoke `interpret/edna-interpret` instead.

## 0. Inputs / Outputs contract

### Inputs (consumed)

| Path / source | Required? | Notes |
| --- | --- | --- |
| User-provided run parameters (marker, primers, amplicon length range, grouping variable, reference level, decontam threshold, kingdom filter) | yes | Gathered in Steps 1 + 4 of the procedure below |
| Path to sample manifest (CSV / TSV) | yes | Validated in Step 3.1 |
| Path to metadata TSV | yes | Validated in Step 3.2 |
| Path to IDTAXA model (`.rds`) | yes | Validated in Step 3.3 |
| `results/{run_id}/pipeline_state.json` | conditional | If present → resume path (Step 2); otherwise new run (Step 3+) |

### Outputs (produced)

| Path | Format | Owner | Notes |
| --- | --- | --- | --- |
| `results/{run_id}/pipeline_state.json` | JSON | this skill | **Machine contract for `run/edna-run`.** Includes `run_id`, `pipeline`, `marker`, `verdict` (GO / GO-WITH-WARNINGS / NO-GO), `completed_stages`, `last_stage`, `params_used`, `outputs`. The `verdict` field is the gate `run/edna-run` reads. |
| `results/{run_id}/params.json` | JSON | this skill | **Full parameter file for `nextflow run -params-file`.** Merged on top of the marker preset (`params/{marker}.json`). |
| `results/{run_id}/intake_evidence.txt` | text | this skill | Raw evidence output (file-existence checks, line counts, column-name parses, `which nextflow`, `df -h`) — kept for debugging. |

### Verdict gate

| Verdict | Meaning | Downstream behaviour |
| --- | --- | --- |
| `GO` | All evidence items pass with no warnings | `run/edna-run` proceeds without prompts |
| `GO-WITH-WARNINGS` | All evidence items pass with ≤ 1 warning | `run/edna-run` proceeds after one confirmation prompt |
| `NO-GO` | Any evidence item fails | `run/edna-run` refuses to execute; route to the failing evidence item for remediation |

## 0.5 Ask-User Stop Points

This sub-skill has **7 stop points** (SP1–SP7). Each fires only when the evidence is ambiguous. The format is **Evidence + Recommend + Options**. If the evidence is unambiguous, the agent auto-picks the default and proceeds silently.

### SP1 — Marker gene ambiguous

| Trigger | Evidence check | Action |
| --- | --- | --- |
| User did not say which marker (16S / 18S-V9 / COI / 12S) | Preset cannot be selected | Ask: "I see no marker in your brief. Pick: (A) **16S** (prokaryotes; 341F/806R; 350–550 bp amplicon), (B) **18S-V9** (eukaryotes, aquatic biodiversity), (C) **COI** (eukaryotes, invertebrates), (D) **12S** (eukaryotes, vertebrates; MiFish-U/E primers; 150–200 bp amplicon), (E) I'll tell you now" |
| R1 reads start with `TCGGT…` (6-mer) AND R2 reads start with `CATAGTGGGGTATCTAATCCCAGTTTG` (28 bp) | Reads strongly indicate **MiFish-U 12S** — do not auto-pick 16S just because the 6-mer matches 16S V3 interior | Ask: "R2 begins with the MiFish-U reverse primer `CATAGTGGGGTATCTAATCCCAGTTTG`. R1 has `GTCGGTAAAACTCGTGCCAGC` (MiFish-U forward) at offset 0–5. Pick: (A) **12S / MiFish-U** (strongly recommended — matches R2 reverse primer signature), (B) different marker — I'll tell you, (C) abort" |
| R1 reads start with `CCTACGGG…` (341F, 16S V3-V4) AND R2 reads start with `GGACTACHVGGGTWTCTAATCC` (806R) | Reads strongly indicate **16S V3-V4** | Ask: "R2 begins with the 806R reverse primer `GGACTACHVGGGTWTCTAATCC`. R1 has the 341F forward primer at offset 0. Pick: (A) **16S V3-V4** (recommended), (B) different marker, (C) abort" |

**Auto-pick when**: user provides one of `16S` / `18S-V9` / `COI` / `12S` in the initial brief. Default: 16S with a warning (most common).

**CRITICAL: Never auto-pick 16S just because R1 reads start with the 6-mer `TCGGT`.** That 6-mer appears in BOTH the 16S V3 interior (`…TCGGTAAAACTCGTGCCAGC…`) AND the MiFish-U forward primer (`GTCGGTAAAACTCGTGCCAGC`). The discriminating step is **R2's reverse primer signature** — always check R2 before assigning a marker. See signature-library entry "Marker detection: the `TCGGT` ambiguity" for the full lesson from the AZAM_NSPSF battle-test.

### SP2 — Manifest schema unparseable

| Trigger | Evidence check | Action |
| --- | --- | --- |
| Manifest filename lacks `.csv` / `.tsv` extension, OR first line has neither `sample-id,absolute-filepath` (SE) nor `sample-id,read1-filepath,read2-filepath` (PE) | Schema is ambiguous | Ask: "I see manifest at `<path>` but can't infer the column schema. Pick: (A) it's CSV SE with `sample-id,absolute-filepath`, (B) it's CSV PE with `sample-id,read1-filepath,read2-filepath`, (C) it's TSV — I'll paste the first 3 lines now" |

**Auto-pick when**: filename ends in `.csv` AND first line contains `sample-id,absolute-filepath` (SE) OR `sample-id,read1-filepath,read2-filepath` (PE); OR filename ends in `.tsv` and the same column names appear tab-separated. No ask.

### SP3 — Sample-count mismatch

| Trigger | Evidence check | Action |
| --- | --- | --- |
| Manifest row count differs from the count of distinct FASTQ files referenced | Real ambiguity (typo in path, or partial upload) | Ask: "Manifest lists `<M>` samples but `<N>` distinct FASTQ paths were found (`<missing_or_extra>`). Pick: (A) accept this and continue with the manifest's `<M>` (manifest is authoritative), (B) re-check my upload — I'll fix the path, (C) abort" |

**Auto-pick when**: manifest row count == distinct FASTQ path count. No ask.

### SP4 — Negative-control column missing in metadata

| Trigger | Evidence check | Action |
| --- | --- | --- |
| Metadata TSV has no `is_negative` column (or equivalent boolean) | Decontam will silently disable | Ask: "Metadata has no `is_negative` column. Decontam needs to know which samples are negative controls. Pick: (A) add an `is_negative` column with TRUE/FALSE for each sample (recommended), (B) run without decontam (skip blank filtering — risk of reagent contamination), (C) abort" |

**Auto-pick when**: metadata has `is_negative` column with at least one TRUE row. No ask.

### SP5 — Tool missing in pixi env

| Trigger | Evidence check | Action |
| --- | --- | --- |
| `which nextflow` returns nothing | Tool missing | Ask: "Nextflow isn't on PATH. Pick: (A) install via `curl -s https://get.nextflow.io \| bash` (recommended), (B) it's installed somewhere else — I'll give you the path, (C) abort" |
| `which pixi` returns nothing | Tool missing | Ask: "Pixi isn't on PATH. nf-edna's per-stage pixi envs need pixi to resolve. Pick: (A) install via `curl -fsSL https://pixi.sh/install.sh \| bash` (recommended), (B) abort" |

**Auto-pick when**: both `nextflow ≥ 23.10.0` and `pixi` are on PATH and `--version` succeeds. No ask.

### SP6 — IDTAXA model file unrecognised

| Trigger | Evidence check | Action |
| --- | --- | --- |
| IDTAXA model path doesn't end in `.rds`, OR file size < 100 KB (likely corrupt) | Model is unusable | Ask: "IDTAXA model at `<path>` doesn't look right (missing `.rds` extension, or < 100 KB). Pick: (A) I'll give you the correct path, (B) train a new one with `bin/train_idtaxa_model.R` from a reference FASTA + taxonomy headers (I'll need the FASTA path), (C) abort" |

**Auto-pick when**: file ends in `.rds` AND file size ≥ 100 KB. No ask.

### SP7 — Disk space low

| Trigger | Evidence check | Action |
| --- | --- | --- |
| Free space at `results/` < 10 GB | Nextflow `work/` may run out | Ask: "Only `<X> GB` free where `results/` will live. nf-edna's intermediate work directory typically needs ≥ 10 GB. Pick: (A) free up disk by clearing intermediate files (recommended), (B) move `results/` to a larger disk — I'll give you the new path, (C) abort" |

**Auto-pick when**: free space ≥ 50 GB (silent go). 10–50 GB → `GO-WITH-WARNINGS` with one prompt (no ask — the warning is enough). < 10 GB → `NO-GO` unless overridden.

### Operating rule

> **Auto-pick when the evidence is unambiguous; ask when the agent genuinely cannot decide.** When asking, present the evidence first, then the recommendation, then 2–4 concrete options. Do not ask "what do you want?" — ask "I see X, recommend Y, which one of A/B/C?"

## Description

You are the intake agent for an eDNA metabarcoding analysis. Your job is to gather every parameter needed to run the pipeline, validate that all required files exist, and write the initial `pipeline_state.json` with the verdict gate set. You never assume defaults silently — every parameter is either provided by the scientist or explicitly asked for.

The design follows `bettamt-preflight` exactly: every recommendation is cited back to a measured piece of evidence. The agent does not invent parameters — it computes them.

## Prerequisites

- **Environment**: pixi env with `python ≥ 3.10`, `pyyaml`, `git`. The sub-skill does NOT need any bioinformatics tools.
- **Upstream evidence**: optionally `results/{run_id}/pipeline_state.json` (resume path).
- **User-provided inputs** (gather once, at the top):
  - Marker gene (16S / 18S-V9 / COI / 12S)
  - Sample manifest path (CSV / TSV)
  - Metadata TSV path
  - IDTAXA model path (`.rds`)
  - Primer sequences + amplicon length range (defaults available per marker)
  - Grouping variable for diversity/association
  - Reference level for DAA
  - Decontam threshold (default 0.1)
  - Kingdom filter (defaults per marker)

## Procedure

The procedure has **three phases**: (1) gather inputs, (2) compute evidence (six items, see SP1–SP7), (3) write outputs.

### Step 1 — Determine pipeline and mode

Ask if not already stated:

> "Which marker gene are you running?
> - **16S** (prokaryotes, V3-V4 or similar) → preset `params/16s.json`
> - **18S V9** (eukaryotes, aquatic biodiversity) → preset `params/18s-v9.json`
> - **COI** (eukaryotes, invertebrates) → preset `params/coi.json`
> - **12S** (eukaryotes, vertebrates) → preset `params/12s.json`"

Then ask:

> "Are you starting a new run, or resuming an existing one? If resuming, provide the `run_id`."

### Step 2 — Resume path (if run_id provided)

Read `results/{run_id}/pipeline_state.json`. Report:

- Which stages are already complete (`completed_stages`)
- Which stages remain
- What parameters were used
- What the previous `verdict` was

Ask: "Do you want to continue from where this left off, or start over?"

If continuing: skip to Step 6 (confirm and write).
If starting over: proceed from Step 3 with a new `run_id`.

### Step 3 — Validate required files

Ask for the following, one at a time if not already provided. After each answer, check that the file/path exists using the Read tool or Bash.

1. **Manifest CSV** — path to sample manifest. Required columns depend on read type:
   - Single-end: `sample-id`, `absolute-filepath`
   - Paired-end: `sample-id`, `read1-filepath`, `read2-filepath`

   After receiving path: read the first 3 lines and confirm sample count and column names. This is evidence item **E2** (manifest schema).

2. **Metadata TSV** — path to sample metadata. Must contain at minimum a `sample-id` column. Ask the scientist to confirm the column used for grouping (e.g. `treatment`, `site`). Also check for `is_negative` column (evidence item **E4**).

3. **IDTAXA model** — path to `.rds` file. If the scientist doesn't have one, explain:
   > "You need a pre-trained IDTAXA model for your reference database. If you have a reference FASTA with taxonomy headers, I can help you train a minimal model using `train_idtaxa_model.R`."

   File existence + size check is evidence item **E6**.

### Step 4 — Elicit biological parameters

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

Confirm the appropriate kingdom filter (already set by the marker preset, override only if the scientist's experiment differs):
- 16S: `Bacteria,Archaea` (default)
- 18S V9 / COI / 12S: `Eukaryota` (default)

Ask only if the scientist's experiment might differ (e.g., they specifically want to exclude Archaea).

### Step 5 — Optional parameters

Ask these only if the scientist indicates they want to customise:

- Number of community clusters for beta diversity (default: auto-determined)
- DAA taxonomic level (default: `Genus` for 16S, `Species` for eukaryotes)
- Top N taxa to plot in differential abundance (default: 20)

### Step 6 — Tool and disk checks (evidence items E5 + E7)

Before confirming, run the two background checks that don't depend on user input:

```bash
# E5: tool availability
which nextflow && nextflow -version | head -1
which pixi && pixi --version

# E7: disk space at the path that will hold results/
df -h "$(dirname results/{run_id})"
```

If `which nextflow` or `which pixi` fails → trigger SP5 (ask user to install or provide a path).
If free space < 10 GB → trigger SP7.

### Step 7 — Compute evidence + emit verdict

Append each evidence item to `results/{run_id}/intake_evidence.txt`:

| Code | Evidence item | Pass criterion | Verdict impact |
| --- | --- | --- | --- |
| **E1** | Marker gene selected | One of 16S / 18S-V9 / COI / 12S | Required for `GO` |
| **E2** | Manifest schema valid | SP2 auto-pick succeeded | Required for `GO` |
| **E3** | Sample-count parity | Manifest row count == distinct FASTQ count | Required for `GO` |
| **E4** | Metadata completeness | `sample-id` + `is_negative` columns present | `GO-WITH-WARNINGS` if `is_negative` missing; `NO-GO` if `sample-id` missing |
| **E5** | Tool availability | `nextflow` + `pixi` on PATH, versions parse | Required for `GO` |
| **E6** | IDTAXA model valid | `.rds` extension + ≥ 100 KB | Required for `GO` |
| **E7** | Disk space | Free at `results/` ≥ 10 GB | `GO-WITH-WARNINGS` for 10–50 GB; `NO-GO` below 10 GB |

Compute the overall verdict:

```text
if any evidence item is "NO-GO"  → verdict = "NO-GO"
elif any item is "GO-WITH-WARNINGS" → verdict = "GO-WITH-WARNINGS"
else → verdict = "GO"
```

### Step 8 — Confirm all parameters

Display a summary table of all collected parameters and ask for confirmation:

```
Run ID:           {run_id}
Pipeline:         nf-edna
Marker:           {marker}
Manifest:         {input_manifest}  ({N} samples, {SE/PE})
Metadata:         {metadata}  (grouping: {grouping_variable}, neg: {is_negative})
IDTAXA model:     {idtaxa_model}
Primers fwd:      {primers_fwd}
Primers rev:      {primers_rev}
Length range:     {min_length}–{max_length} bp
Kingdoms:         {kingdoms}
Reference level:  {reference_level}
DAA level:        {daa_level}
Decontam thresh:  {decontam_threshold}

Evidence:
  E1 marker         ✓ {marker}
  E2 manifest       ✓ {SE/PE}, {N} samples
  E3 sample parity  ✓ {M} manifest rows, {N} FASTQ files
  E4 metadata       ✓ / ⚠ / ✗  (neg col: {yes/no/missing})
  E5 tools          ✓ nextflow {ver} pixi {ver}
  E6 IDTAXA model   ✓ {size_mb} MB
  E7 disk space     ✓ / ⚠ / ✗  ({free_gb} GB free)

Overall verdict: {GO / GO-WITH-WARNINGS / NO-GO}
```

Ask: "Does this look correct? Type 'yes' to proceed, correct any parameter, or address any NO-GO items."

### Step 9 — Write outputs

Once confirmed:

1. **Generate `run_id`**: `{marker_prefix}-{YYYYMMDD}-{short_descriptor}`
   - Ask for a short descriptor (e.g. site name, experiment ID): "What short label should identify this run? (e.g., `siteA`, `batch2`)"
   - Marker prefixes: 16S → `16s`, 18S-V9 → `18sv9`, COI → `coi`, 12S → `12s`

2. **Write `results/{run_id}/pipeline_state.json`** with the verdict gate field:

```json
{
  "run_id": "{run_id}",
  "pipeline": "nf-edna",
  "marker": "{marker}",
  "verdict": "GO | GO-WITH-WARNINGS | NO-GO",
  "completed_stages": [],
  "last_stage": "intake",
  "evidence": {
    "E1_marker": "pass | warn | fail",
    "E2_manifest_schema": "pass | warn | fail",
    "E3_sample_count_parity": "pass | warn | fail",
    "E4_metadata_completeness": "pass | warn | fail",
    "E5_tool_availability": "pass | warn | fail",
    "E6_idtaxa_model": "pass | warn | fail",
    "E7_disk_space": "pass | warn | fail"
  },
  "params_used": {
    "input_manifest": "...",
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

   This file is merged on top of the marker preset (`params/{16s|18s-v9|coi|12s}.json`) — only include values here that differ from the chosen preset, plus the always-required run-specific fields below:

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

### Step 10 — Hand off

Tell the scientist:

> "Intake complete. Run ID: `{run_id}`. Verdict: `{GO / GO-WITH-WARNINGS / NO-GO}`.
>
> To execute the pipeline: `run/edna-run`
> To run a specific stage only, invoke `run/edna-run` and specify the stage when prompted."

## Troubleshooting — Signature library

| Signature in stderr / log | Likely cause | Suggested fix |
| --- | --- | --- |
| `Manifest has fewer samples than expected` | FASTQ files weren't all uploaded, or paths in manifest point to a different directory | `ls -la $(dirname <first-FASTpath>)`; cross-reference manifest paths with actual files |
| `Metadata 'is_negative' column missing — decontam will silently disable` | User skipped SP4 or the metadata CSV was exported without the negative-control flag | Re-export metadata with `is_negative=TRUE/FALSE` per sample, or accept `GO-WITH-WARNINGS` and skip decontam |
| `Primer sequence contains ambiguous bases that cutadapt can't parse` | IUPAC codes in user-supplied primers are non-standard, or the primer was pasted with whitespace | Trim whitespace; verify IUPAC codes against `cutadapt --help` (it accepts A/C/G/T/N + W/S/R/Y/K/M/B/D/H/V) |
| `IDTAXA model file is corrupt or wrong format` | File is not a serialized R object (`saveRDS`), or the IDTAXA training script ran but didn't save | Retrain with `bin/train_idtaxa_model.R --input <fasta> --taxonomy <headers.tsv> --output <model.rds>` |
| `nextflow: command not found` | Nextflow not on PATH | `curl -s https://get.nextflow.io \| bash && mv nextflow ~/bin/` (or any directory on PATH) |
| `pixi: command not found` | Pixi not on PATH | `curl -fsSL https://pixi.sh/install.sh \| bash` then re-source `~/.bashrc` |
| `No space left on device` while resolving per-stage pixi env | First-run pixi env resolution can take 1–3 GB per stage | Free ≥ 10 GB before intake, or move `results/` to a larger disk |
| `Metadata 'grouping_variable' has only 1 unique value` | All samples have the same `treatment` / `site` / etc. label | Diversity and DAA analyses will be uninformative; either expand the metadata or accept that only the QC + classify stages are meaningful for this run |

## Verification

- [ ] `results/{run_id}/pipeline_state.json` exists with `verdict` set to one of `GO` / `GO-WITH-WARNINGS` / `NO-GO`.
- [ ] `results/{run_id}/params.json` exists and merges cleanly on top of `params/{marker}.json` (no missing required keys).
- [ ] `results/{run_id}/intake_evidence.txt` exists with all 7 evidence items recorded.
- [ ] The downstream `run/edna-run` sub-skill accepts the run (verdict ≥ `GO-WITH-WARNINGS`) OR refuses with a clear pointer to the failing evidence item.

## Invariants

- Never silently assume a default. Every parameter is either given or asked.
- Validate every file path before accepting it. If a file does not exist, say so and ask again.
- If the manifest references FASTQ paths, spot-check that at least one exists.
- Never proceed to Step 9 (write) without explicit confirmation in Step 8.
- The verdict gate is **never** overridden silently — if SP1–SP7 would emit `NO-GO`, ask the user before writing `NO-GO` to `pipeline_state.json`.