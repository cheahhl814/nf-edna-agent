---
name: edna:run
description: Execute the correct nf-edna pipeline stage(s) for the run's marker preset, monitor progress, and update pipeline_state.json. Invoke after edna:intake has written the initial state.
---

# edna:run

You are the pipeline execution agent for an eDNA metabarcoding analysis. Your job is to read the current `pipeline_state.json`, determine what to run next, show the scientist the exact command, and execute it after confirmation.

## Step 1 — Locate the run

Ask if not already stated:

> "What is the `run_id` for this run?"

Read `results/{run_id}/pipeline_state.json`. If it does not exist, stop:

> "No pipeline_state.json found for run `{run_id}`. Please run `/edna:intake` first."

## Step 2 — Determine what to run

From `pipeline_state.json`:
- `pipeline`: pipeline directory to use (always `nf-edna` now)
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
| `association`  | All stages complete — suggest `/edna:interpret` |

Ask the scientist if they want to:
1. Run the **next stage only** (incremental)
2. Run **all remaining stages** (full pipeline from current point)
3. Run a **specific stage** (ask which one)

Note: Entry points `QC_ONLY`, `DENOISE_ONLY`, `CLASSIFY_ONLY`, `DIVERSITY_ONLY` each run all stages from the beginning up to and including that stage (they are cumulative, not isolated). To run from a mid-point, the pipeline must be run with `-resume` so Nextflow reuses cached work from prior stages.

## Step 3 — Construct the command

Determine:
- `PIPELINE_DIR`: `nf-edna` (relative to `AMPLICON/`)
- `MARKER_PRESET`: `params/{16s|18s-v9|coi|12s}.json` inside `PIPELINE_DIR`, chosen from `pipeline_state.json`'s `marker` field
- `PARAMS_FILE`: `results/{run_id}/params.json`
- `ENTRY`: the Nextflow entry point workflow name (or omit for default full workflow)
- `RESUME`: add `-resume` if any stages are already complete

Note: `-params-file` accepts only one file, so pass the marker preset first and let `PARAMS_FILE` override on top via a second `-params-file` flag — Nextflow merges multiple `-params-file` flags left-to-right, last one wins on conflicts.

For running all remaining stages from the start:
```bash
nextflow run {PIPELINE_DIR} -params-file {PIPELINE_DIR}/{MARKER_PRESET} -params-file {PARAMS_FILE} -resume
```

For running up to a specific stage:
```bash
nextflow run {PIPELINE_DIR} -entry {ENTRY_POINT} -params-file {PIPELINE_DIR}/{MARKER_PRESET} -params-file {PARAMS_FILE} -resume
```

Entry point mapping:
- Through QC only: `-entry QC_ONLY`
- Through DENOISE: `-entry DENOISE_ONLY`
- Through CLASSIFY: `-entry CLASSIFY_ONLY`
- Through DIVERSITY: `-entry DIVERSITY_ONLY`
- Full pipeline (all stages): omit `-entry` (uses default workflow)

## Step 4 — Show command and wait for confirmation

Display the full command and ask:

> "I will run:
>
> ```bash
> cd {AMPLICON_PATH}/{PIPELINE_DIR}
> {nextflow command}
> ```
>
> Proceed? (yes / no / change a parameter)"

If the scientist wants to change a parameter, update `results/{run_id}/params.json` accordingly and show the revised command.

Do not execute until the scientist confirms.

## Step 5 — Execute and monitor

Run the command using the Bash tool. Stream output as it runs.

Watch for:
- `Launching` — pipeline started
- `[xx/xxxxxx] process > WORKFLOW:process_name` — stage progress
- `Completed at:` — successful completion
- `ERROR` or `FAILED` — failure (see Step 6)

Report progress to the scientist as stages complete:
> "✓ QC complete (188/200 reads survived trimming)"
> "✓ DENOISE complete (47 ASVs across 3 samples)"

## Step 6 — Handle failures

If a process fails (non-zero exit, ERROR in log):

1. Extract the relevant log excerpt:
```bash
grep -A 20 "ERROR\|FAILED\|Command exit" .nextflow.log | tail -40
```

2. Explain the likely cause in plain language. Common causes:
   - **QC/trim failure**: primer sequences not found in reads — check orientation, check length range
   - **NGmerge failure**: reads may be SE not PE, or insert size too small
   - **VSEARCH failure**: no reads survive dereplication — too few reads or stringent min_length
   - **IDTAXA failure**: model file corrupt or wrong format — retrain
   - **R script failure**: missing package, bad metadata column name, insufficient samples for statistics
   - **Julia failure**: decontam script — check neg_col name matches metadata

3. Offer three options:
   > "What would you like to do?
   > 1. **Retry** — adjust a parameter and rerun (tell me which parameter to change)
   > 2. **Skip** this stage and continue with the next
   > 3. **Abort** this run"

4. Do **not** update `pipeline_state.json` for a failed stage.

If retrying: update `results/{run_id}/params.json` with the new parameter value, then go back to Step 4.

If skipping: note the skipped stage in your response to the scientist and proceed to the next stage. Do not add the skipped stage to `completed_stages`.

If aborting: tell the scientist the run state is preserved and can be resumed later by re-running `/edna:run` with the same `run_id`.

## Step 7 — Update state on success

After each stage completes successfully, read the current `pipeline_state.json` and write an updated version with:
- `completed_stages` extended by the newly completed stage(s)
- `last_stage` set to the most recently completed stage
- `outputs` updated with paths to new outputs

Use the Write tool to overwrite `results/{run_id}/pipeline_state.json`.

## Step 8 — Generate run summary

When all stages are complete (or when `association` is the last completed stage), generate the AI-readable run summary:

```bash
cd {AMPLICON_PATH}
python3 nf-edna/bin/summarise_run.py \
  --results_dir analyses/{analysis_id}/results \
  --run_id {run_id}
```

This writes `results/{run_id}/run_summary.json`, which pre-compiles all statistics (read flow, ASV counts, taxonomy, top taxa, alpha/beta diversity, DA, correlations, blank QC warnings) into a single compact file used by `/edna:interpret`.

If the script is not present at that path, look for it at `analyses/*/results/summarise_run.py` (older analyses may still have a local copy).

## Step 9 — Hand off

When all requested stages are complete:

> "Pipeline complete through `{last_stage}`.
> Completed stages: {completed_stages}
>
> Run summary written to `results/{run_id}/run_summary.json`.
> To interpret results: `/edna:interpret`"

If only some stages were requested and more remain:
> "`{last_stage}` complete. Run `/edna:run` again to continue with the next stage, or `/edna:interpret` if you want to review results so far."

## Invariants

- Never execute a Nextflow command without showing it first and waiting for explicit confirmation.
- Never update `pipeline_state.json` for a stage that failed.
- Always use `-resume` when any prior stage has completed, so Nextflow reuses cached work.
- Always run Nextflow from within the pipeline directory (`nf-edna/`) so relative paths in configs resolve correctly.
- Always pass the marker preset (`-params-file nf-edna/params/{marker}.json`) before the run's own `params.json`, so the run's values take precedence.
