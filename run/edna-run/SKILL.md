---
name: edna-run
description: "Execute the correct nf-edna pipeline stage(s) for the run's marker preset, monitor progress, and update pipeline_state.json. Refuses to execute when the upstream preflight/edna-intake verdict is NO-GO. Has 4 explicit ask-user stop points (SP1–SP4) that fire only when evidence is ambiguous. Triggers: 'run eDNA pipeline', 'execute eDNA stages', 'nextflow run nf-edna', 'continue eDNA run', 'eDNA QC stage', 'eDNA denoise', 'eDNA classify', 'eDNA diversity', 'eDNA association'."
version: 1.1.3
updated: "2026-08-19"
triggers:
  - "run eDNA pipeline"
  - "execute eDNA stages"
  - "nextflow run nf-edna"
  - "continue eDNA run"
  - "eDNA QC stage"
  - "eDNA denoise"
  - "eDNA classify"
  - "eDNA diversity"
  - "eDNA association"
---

# edna-run

> **v1.1.0.** Adds the canonical BettaMt structure (§0 Inputs/Outputs contract, §0.5 Ask-User Stop Points with Evidence + Recommend + Options, §Troubleshooting — Signature library, preflight verdict-gate enforcement). The procedure body (Steps 1–9 below) is unchanged from v1.0.0 — only the structured wrappers were added. Mirrors `bioinfo-skill-creator/preflight/skill-creator-preflight/SKILL.md` pattern (Evidence + Recommend + Options for every ambiguity).

## Audience

This skill serves two simultaneous audiences:

- **AI Coding Agents** — triggered by the phrases above. The agent must read `pipeline_state.json`, enforce the verdict gate (SP1), determine the next stage to run (Step 2), construct the exact `nextflow run` command with the correct `-params-file` chain (Step 3), show it to the scientist before execution (Step 4), and update state only after confirmed success (Step 7).
- **Human eDNA scientists** — read this document as a workflow guide. The `## When to Use` / `## Do NOT use` sections explain *why* the verdict gate exists (no compute without validated inputs), *why* the command must be shown before execution (mistakes cost hours of Nextflow runtime), and *why* `pipeline_state.json` is the source of truth for resumability.

## When to Use This Skill

Use this skill when you need to:

- **Continue** an existing eDNA run whose `pipeline_state.json` exists (verdict ≥ `GO-WITH-WARNINGS`).
- **Run one or more pipeline stages** (`qc`, `denoise`, `classify`, `diversity`, `association`) with the correct `-params-file` chain.
- **Resume** a partially-completed run via Nextflow's `-resume` (caches from prior stages are reused).
- **Update `pipeline_state.json`** after each successful stage so the next invocation knows where to pick up.

## Do NOT use this skill

- If there is **no `pipeline_state.json`** for the run → invoke `preflight/edna-intake` first. This sub-skill refuses to run without intake-completed state (SP1).
- If the upstream intake verdict is **`NO-GO`** → fix the failing evidence item in `pipeline_state.json.evidence` first, then re-run intake.
- If you want to **interpret already-completed results** → invoke `interpret/edna-interpret` instead.
- If you want to **change the marker gene or presets mid-run** → this requires a new intake (a new `run_id`); do not edit `pipeline_state.json` by hand.
- If you only want to **look at the Nextflow log** → use `tail -f .nextflow.log` directly, no skill needed.

## 0. Inputs / Outputs contract

### Inputs (consumed)

| Path | Source | Required? | Notes |
| --- | --- | --- | --- |
| `results/{run_id}/pipeline_state.json` | `preflight/edna-intake` | yes | Must exist with `verdict ∈ {GO, GO-WITH-WARNINGS}`. The `pipeline`, `marker`, `completed_stages`, `last_stage` fields drive stage routing. |
| `results/{run_id}/params.json` | `preflight/edna-intake` | yes | The run-specific parameter overrides; merged on top of `params/{marker}.json` via a second `-params-file`. |
| `params/{marker}.json` (16s / 18s-v9 / coi / 12s) | this skill (skill-bundled) | yes | The marker-specific preset; passed as the FIRST `-params-file` so user overrides win. |

### Outputs (produced)

| Path | Format | Owner | Notes |
| --- | --- | --- | --- |
| `results/{run_id}/pipeline_state.json` | JSON (updated) | this skill | After each successful stage: extend `completed_stages`, update `last_stage`, append new paths to `outputs`. **Never** update on failure (Step 7 invariant). |
| `results/{run_id}/run_summary.json` | JSON | `bin/summarise_run.py` (invoked by this skill) | Compact, LLM-loadable summary of the full run — read by `interpret/edna-interpret`. Written when `association` completes (Step 8). |
| `results/{run_id}/{stage}_output/...` | per-stage outputs | Nextflow pipeline | Stage-specific outputs (trimmed FASTQs, ASV tables, taxonomy files, diversity metrics, DAA results). |

### Verdict gate enforcement

Before constructing any command, **read `pipeline_state.json.verdict`**. If `NO-GO` or missing → SP1 fires (refuse to execute). If `GO-WITH-WARNINGS` → one confirmation prompt ("verdict is GO-WITH-WARNINGS — continue?") before Step 3.

## 0.5 Ask-User Stop Points

This sub-skill has **4 stop points** (SP1–SP4). Each fires only when the evidence is ambiguous. The format is **Evidence + Recommend + Options**.

### SP1 — Pre-flight verdict gate fails

| Trigger | Evidence check | Action |
| --- | --- | --- |
| `pipeline_state.json` missing OR its `verdict` field is `NO-GO` OR `verdict` field missing | The intake gate has not been passed | Hard-stop: "I see no `pipeline_state.json` for run `{run_id}` (or its verdict is `NO-GO`). Invoke `preflight/edna-intake` first." |
| `pipeline_state.json.verdict == GO-WITH-WARNINGS` | Some evidence items had warnings | Ask: "Verdict is `GO-WITH-WARNINGS` (`<failing evidence items>`). Pick: (A) continue anyway (the warnings are acceptable), (B) re-run intake to fix the warnings (recommended), (C) abort" |

**Auto-pick when**: `verdict == GO`. No ask.

### SP2 — Pipeline-state schema mismatch

| Trigger | Evidence check | Action |
| --- | --- | --- |
| `pipeline` field is not `nf-edna`, OR `marker` field is missing or not one of `16s / 18s-v9 / coi / 12s` | State belongs to a different skill or was corrupted | Ask: "State at `<path>` doesn't look like nf-edna intake (missing `pipeline: nf-edna` or `marker` is `<X>`). Pick: (A) it's an unrelated run — I'll give you the correct `run_id`, (B) it's nf-edna with a typo in `marker` — I'll fix it (only safe if it's a typo, not a marker change), (C) abort" |

**Auto-pick when**: `pipeline == "nf-edna"` AND `marker ∈ {16s, 18s-v9, coi, 12s}`. No ask.

### SP3 — Failure-handling choice

| Trigger | Evidence check | Action |
| --- | --- | --- |
| A Nextflow process exited non-zero OR `ERROR` / `FAILED` appeared in `.nextflow.log` | A stage genuinely failed | Ask: "`<stage>` failed with `<excerpt>`. Pick: (A) **retry** — adjust a parameter in `params.json` and rerun with `-resume` (tell me which), (B) **skip** this stage and continue with the next (record the skip in the report), (C) **abort** this run (state is preserved, resumable later)" |

**Auto-pick when**: stage succeeded. No ask.

### SP4 — Resume-from-stage ambiguity

| Trigger | Evidence check | Action |
| --- | --- | --- |
| `completed_stages` has ≥ 2 entries, AND user did not specify "next stage only" / "all remaining" | Multiple valid resumptions | Ask: "I see `<N>` stages already complete (`<list>`). Pick: (A) run only the **next** stage (incremental), (B) run **all remaining** stages (full pipeline from current point), (C) run a **specific** stage from the entry-point table (tell me which)" |

**Auto-pick when**: `completed_stages` has ≤ 1 entry AND user said "continue" (default: next stage only). No ask.

### Operating rule

> **Auto-pick when the evidence is unambiguous; ask when the agent genuinely cannot decide.** When asking, present the evidence first, then the recommendation, then 2–4 concrete options. Do not ask "what do you want?" — ask "I see X, recommend Y, which one of A/B/C?"

## Description

You are the pipeline execution agent for an eDNA metabarcoding analysis. Your job is to read the current `pipeline_state.json`, determine what to run next, show the scientist the exact command, and execute it after confirmation.

## Prerequisites

- **Environment**: `nextflow ≥ 23.10.0` and `pixi` on PATH (already validated by `preflight/edna-intake` evidence item E5).
- **Upstream evidence**: `results/{run_id}/pipeline_state.json` with verdict ≥ `GO-WITH-WARNINGS` (SP1).
- **User-provided inputs**: `run_id` (gathered in Step 1 below); optionally a stage choice (incremental / all / specific).

## Procedure

### Step 1 — Locate the run

Ask if not already stated:

> "What is the `run_id` for this run?"

Read `results/{run_id}/pipeline_state.json`. **Enforce the verdict gate (SP1)**: if missing, `NO-GO`, or `verdict < GO-WITH-WARNINGS` → refuse to proceed.

> "No pipeline_state.json found for run `{run_id}` (or verdict is `NO-GO`). Please run `preflight/edna-intake` first."

### Step 2 — Determine what to run

From `pipeline_state.json`:
- `pipeline`: pipeline directory to use (always `nf-edna` for this skill — SP2 enforces the schema)
- `marker`: which preset file to pass via `-params-file` in addition to the run's `params.json` (`16s.json`, `18s-v9.json`, `coi.json`, or `12s.json`, matched by lowercasing/normalizing `marker`)
- `completed_stages`: what has already run
- `last_stage`: last completed stage

Determine the next stage(s):

| `last_stage`   | Next stage to run |
|----------------|-------------------|
| `intake`       | `qc` (entry: default workflow or QC_ONLY) |
| `qc`           | `denoise` (entry: DENOISE_ONLY) |
| `denoise`      | `classify` (entry: CLASSIFY_ONLY) |
| `classify`     | `diversity` (entry: DIVERSITY_ONLY) |
| `diversity`    | `association` (full default workflow) |
| `association`  | All stages complete — suggest `interpret/edna-interpret` |

If `completed_stages` has ≥ 2 entries, SP4 fires (ask user incremental vs full vs specific). Otherwise, default to "next stage only".

Note: Entry points `QC_ONLY`, `DENOISE_ONLY`, `CLASSIFY_ONLY`, `DIVERSITY_ONLY` each run all stages from the beginning up to and including that stage (they are cumulative, not isolated). To run from a mid-point, the pipeline must be run with `-resume` so Nextflow reuses cached work from prior stages.

### Step 3 — Construct the command

Determine:
- `PIPELINE_DIR`: `.` (the current skill root — the pipeline is flattened at skill root since v1.0.0)
- `MARKER_PRESET`: `params/{16s|18s-v9|coi|12s}.json` inside the skill root, chosen from `pipeline_state.json`'s `marker` field
- `PARAMS_FILE`: `results/{run_id}/params.json`
- `ENTRY`: the Nextflow entry point workflow name (or omit for default full workflow)
- `RESUME`: add `-resume` if any stages are already complete

Note: `-params-file` accepts only one file. **Nextflow ≥ 24 rejects multiple `-params-file` flags** with `Can only specify option -params-file once` — the v1.0.0 body instructed this incorrectly. **Workaround:** merge `params/{marker}.json` (preset) + `results/{run_id}/params.json` (run-specific overrides, last wins) into one JSON object, then pass a single `-params-file <merged>.json`. See signature-library entry for this.

For running all remaining stages from the start:
```bash
nextflow run . -params-file <merged_params.json> -resume
```

For running up to a specific stage:
```bash
nextflow run . -entry {ENTRY_POINT} -params-file <merged_params.json> -resume
```

Entry point mapping:
- Through QC only: `-entry QC_ONLY`
- Through DENOISE: `-entry DENOISE_ONLY`
- Through CLASSIFY: `-entry CLASSIFY_ONLY`
- Through DIVERSITY: `-entry DIVERSITY_ONLY`
- Full pipeline (all stages): omit `-entry` (uses default workflow)

### Step 4 — Show command and wait for confirmation

Display the full command and ask:

> "I will run:
>
> ```bash
> cd {SKILL_ROOT}
> {nextflow command}
> ```
>
> Proceed? (yes / no / change a parameter)"

If the scientist wants to change a parameter, update `results/{run_id}/params.json` accordingly and show the revised command.

Do not execute until the scientist confirms.

### Step 5 — Execute and monitor

Run the command using the Bash tool. Stream output as it runs.

Watch for:
- `Launching` — pipeline started
- `[xx/xxxxxx] process > WORKFLOW:process_name` — stage progress
- `Completed at:` — successful completion
- `ERROR` or `FAILED` — failure (trigger SP3)

Report progress to the scientist as stages complete:
> "✓ QC complete (188/200 reads survived trimming)"
> "✓ DENOISE complete (47 ASVs across 3 samples)"

### Step 6 — Handle failures (SP3)

If a process fails (non-zero exit, ERROR in log):

1. Extract the relevant log excerpt:
```bash
grep -A 20 "ERROR\|FAILED\|Command exit" .nextflow.log | tail -40
```

2. Explain the likely cause in plain language. Common signatures are listed in the **Signature library** section below.

3. Present SP3's three options to the scientist (retry / skip / abort).

4. Do **not** update `pipeline_state.json` for a failed stage (invariant).

If retrying: update `results/{run_id}/params.json` with the new parameter value, then go back to Step 4.

If skipping: note the skipped stage in your response to the scientist and proceed to the next stage. Do not add the skipped stage to `completed_stages`.

If aborting: tell the scientist the run state is preserved and can be resumed later by re-running `run/edna-run` with the same `run_id`.

### Step 7 — Update state on success

After each stage completes successfully, read the current `pipeline_state.json` and write an updated version with:
- `completed_stages` extended by the newly completed stage(s)
- `last_stage` set to the most recently completed stage
- `outputs` updated with paths to new outputs

Use the Write tool to overwrite `results/{run_id}/pipeline_state.json`.

### Step 8 — Generate run summary

When all stages are complete (or when `association` is the last completed stage), generate the AI-readable run summary:

```bash
python3 bin/summarise_run.py \
  --results_dir results \
  --run_id {run_id}
```

This writes `results/{run_id}/run_summary.json`, which pre-compiles all statistics (read flow, ASV counts, taxonomy, top taxa, alpha/beta diversity, DA, correlations, blank QC warnings) into a single compact file used by `interpret/edna-interpret`.

If the script is not present at that path, look for it at `results/summarise_run.py` (older runs may still have a local copy).

### Step 9 — Hand off

When all requested stages are complete:

> "Pipeline complete through `{last_stage}`.
> Completed stages: {completed_stages}
>
> Run summary written to `results/{run_id}/run_summary.json`.
> To interpret results: `interpret/edna-interpret`"

If only some stages were requested and more remain:
> "`{last_stage}` complete. Run `run/edna-run` again to continue with the next stage, or `interpret/edna-interpret` if you want to review results so far."

## Troubleshooting — Signature library

| Signature in stderr / log | Likely cause | Suggested fix |
| --- | --- | --- |
| `cutadapt: adapter not found / primer not found in reads` | Primer sequence is wrong, or orientation flipped | Verify primer sequences against the source publication; pass `--primer_mismatch_rate 0.2` to tolerate degenerate bases |
| **Pipeline produced ASVs but species assignments look like Bacteria / Archaea when the dataset should be fish/vertebrate** | **Marker mis-assigned — the 6-mer `TCGGT` at R1 5' is ambiguous between 16S V3 interior and MiFish-U forward primer. Auto-picked 16S without checking R2 reverse primer.** | **Re-run preflight with explicit marker = `12S`. Spot-check: R2 should start with `CATAGTGGGGTATCTAATCCCAGTTTG` (MiFish-U reverse). The lesson: always confirm R2 reverse primer before assigning a marker.** See Finding 0 in `battle-test-report.md` for the AZAM_NSPSF case. |
| `NGmerge: paired reads failed merge (insert size too small)` | Insert size < 30 bp, or reads are actually single-end not paired | Check `read1/read2-filepath` in manifest; if reads are SE, set `paired: false` in `params.json` and run with `-entry QC_ONLY` to start over |
| `VSEARCH: no reads survive dereplication` | Too few reads, or `min_length` is too stringent | Lower `min_length` by 20–30 bp; verify the input FASTQ actually has reads (some pipelines produce empty outputs upstream) |
| `IDTAXA: model file is corrupt or wrong format` | The `.rds` file wasn't saved with `saveRDS()`, or training script aborted | Retrain with `bin/train_idtaxa_model.R --input <fasta> --taxonomy <headers.tsv> --output <model.rds>` |
| `R script: package 'X' is not available` | pixi env for that stage didn't include the R package | Run `pixi add --manifest-path env/{stage}/pixi.toml r-X` then re-run with `-resume` |
| `decontam.jl: neg_col 'is_negative' not found in metadata` | Metadata column-name mismatch (case, separator) | Verify the metadata column name matches exactly: `head -1 metadata.tsv \| tr '\t' ',' \| grep -i negative` |
| `No space left on device` (work dir) | Nextflow work/ filled the disk | Free ≥ 10 GB or move the run to a larger disk; partial work is preserved on `-resume` |
| `nextflow: process cache invalidated` after `pixi add` | pixi env changes invalidate Nextflow's task hash | Run with `-resume` once to recover cached stages; new stages will recompute (expected) |
| `ERROR ~ Command exit (code 137)` | OOM-killed (Linux) | The stage ran out of RAM; reduce `task.memory` in the corresponding module or split the run into smaller batches |
| `Module not found: modules/X.nf` | Pipeline files were moved or the skill was deployed without the `modules/` dir | Verify `diff -rq @skills/nf-edna/ ~/.pi/agent/skills/nf-edna/` — the deploy copy should be md5-identical |
| `Can only specify option -params-file once` | Nextflow ≥ 24 rejects multiple `-params-file` flags (the v1.0.0 body instructed this incorrectly) | Merge `params/{marker}.json` + `results/{run_id}/params.json` into one JSON object before `-params-file <merged>.json`. Use Python: `merged = {**preset, **run_specific}` (last wins) |
| `ERROR: Cannot find Java or it's a wrong version -- Java 8 or later (up to 22) is installed` | Nextflow hard cap of Java 22; sdkman `current` defaults to Java 25 (fails) | Set `JAVA_HOME` to a Java 21 install before running nextflow: `export JAVA_HOME=/home/cheahhl814/.sdkman/candidates/java/21.0.11-tem` (or any Java 8–22) |
| `ERROR: LoadError: ArgumentError: Package ArgParse ... is required but does not seem to be installed` (DENOISE:decontam Julia process) | Julia env in `env/pixi.toml` is missing `ArgParse` and other deps — `Pkg.instantiate()` was never run | Add to `env/pixi.toml` `[dependencies]`: `julia-argparse = "*"` (or run `pixi run --manifest-path env/pixi.toml julia -e 'using Pkg; Pkg.add("ArgParse")'`) |
| `Error in readRDS(model.rdata): unknown input format` (DENOISE:CLASSIFY) | The IDTAXA model file is in DECIPHER's RDX3 binary format (e.g., SILVA trainingFile) — base R `readRDS()` cannot decode it | As of v1.1.1, `bin/idtaxa_rds.R` auto-detects 3 formats: standard RDS, gzipped RDS, and **DECIPHER RDX3** (XZ- or gzip-compressed). It skips the 5-byte `RDX3\n` header and calls `unserialize()` to recover the `trainingSet`. The script also caches a converted `.converted.rds` next to the original. No user action needed — just re-run. |

## Verification

- [ ] `results/{run_id}/pipeline_state.json.verdict` was `GO` or `GO-WITH-WARNINGS` before any `nextflow run` command was constructed (SP1).
- [ ] The exact `nextflow run` command was shown to the scientist and explicitly confirmed (Step 4 invariant).
- [ ] `pipeline_state.json.completed_stages` was extended only after a stage succeeded (Step 7 invariant).
- [ ] `pipeline_state.json.last_stage` matches the most recent successful entry.
- [ ] When `last_stage == association`, `run_summary.json` was generated (Step 8).

## Invariants

- **Never** execute a Nextflow command without showing it first and waiting for explicit confirmation.
- **Never** update `pipeline_state.json` for a stage that failed.
- **Always** use `-resume` when any prior stage has completed, so Nextflow reuses cached work.
- **Always** pass the marker preset (`-params-file params/{marker}.json`) before the run's own `params.json`, so the run's values take precedence.
- **Always** enforce the SP1 verdict gate before Step 3.