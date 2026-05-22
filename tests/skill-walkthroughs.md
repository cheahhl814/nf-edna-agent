# Skill Walkthroughs

Manual test scripts for the three `edna:*` Claude Code skills. Each walkthrough describes the inputs, the expected agent behaviour at each step, and the pass criterion. Run these after any modification to the skill files.

---

## Walkthrough 1 — Intake: complete valid input (16S)

**Setup:** The 16S test fixtures are present:
- `nf-edna-16s/tests/fixtures/manifest.csv` (3 samples, SE)
- `nf-edna-16s/tests/fixtures/metadata.tsv`
- `nf-edna-16s/tests/fixtures/idtaxa_model_16s.rds`

**Script:**

1. Invoke `/edna:intake`
2. When asked for marker/pipeline → reply: `16S`
3. When asked new run or resume → reply: `new`
4. When asked for manifest path → reply: `nf-edna-16s/tests/fixtures/manifest.csv`
5. When asked for metadata path → reply: `nf-edna-16s/tests/fixtures/metadata.tsv`
6. When asked for grouping variable → reply: `treatment`
7. When asked for IDTAXA model → reply: `nf-edna-16s/tests/fixtures/idtaxa_model_16s.rds`
8. When asked for forward primer → reply: `CCTACGGGNGGCWGCAG`
9. When asked for reverse primer → reply: `GACTACNVGGGTWTCTAATCC`
10. When asked for min/max length → reply: `350` and `550`
11. When asked for reference level → reply: `control`
12. When asked for decontam threshold → reply: `0.1`
13. When asked for run label → reply: `walktest`
14. When shown the parameter summary → reply: `yes`

**Pass criteria:**
- Agent asks each missing parameter once (no batching, no skipping)
- Agent validates that each file exists before proceeding
- `results/16s-{date}-walktest/pipeline_state.json` is created with `"completed_stages": []` and `"last_stage": "intake"`
- `results/16s-{date}-walktest/params.json` contains all 14+ parameters with correct values
- Agent ends with instruction to invoke `/edna:run`

---

## Walkthrough 2 — Intake: incomplete input → agent asks for each missing parameter

**Setup:** Same fixtures as Walkthrough 1.

**Script:**

1. Invoke `/edna:intake`
2. When asked for marker/pipeline → reply: `16S`
3. When asked new run or resume → reply: `new`
4. When asked for manifest → reply: `nf-edna-16s/tests/fixtures/manifest.csv`
5. When asked for metadata → reply: `nf-edna-16s/tests/fixtures/metadata.tsv`
6. When asked for grouping variable → reply: `treatment`
7. When asked for IDTAXA model → reply: `nf-edna-16s/tests/fixtures/idtaxa_model_16s.rds`
8. Skip answering primer questions (reply `I don't know` or similar)

**Pass criteria:**
- Agent does not proceed past primers — it asks again or explains what is needed
- Agent does not assume a default primer sequence
- Agent does not write `pipeline_state.json` until all required parameters are collected

---

## Walkthrough 3 — Intake: resume an existing run

**Setup:** A `pipeline_state.json` with `"completed_stages": ["qc", "denoise"]` exists at `results/16s-20260521-siteA/pipeline_state.json` (use `tests/fixtures/pipeline_state_16s_classify.json` as a reference for structure, but save a copy to the right path).

**Script:**

1. Invoke `/edna:intake`
2. When asked new run or resume → reply: `resume`
3. When asked for run_id → reply: `16s-20260521-siteA`

**Pass criteria:**
- Agent reads the existing `pipeline_state.json`
- Agent reports: "QC and DENOISE are complete. CLASSIFY, DIVERSITY, ASSOCIATION remain."
- Agent asks whether to continue or start over
- If continuing: agent skips re-eliciting parameters already in the state file

---

## Walkthrough 4 — Run: show command and wait for confirmation

**Setup:** `results/16s-{date}-walktest/pipeline_state.json` from Walkthrough 1 and matching `params.json` exist.

**Script:**

1. Invoke `/edna:run`
2. When asked for run_id → reply with the run_id from Walkthrough 1
3. When shown the Nextflow command → reply: `no` (do not execute)

**Pass criteria:**
- Agent shows the full `nextflow run nf-edna-16s -params-file ... -resume` command before executing
- Agent does not run Nextflow until confirmation is given
- After `no`: agent does not execute the pipeline and asks what the scientist wants to do instead

---

## Walkthrough 5 — Run: execute against synthetic 16S data

**Setup:** Same as Walkthrough 4, but confirm with `yes`.

**Script:**

1. Invoke `/edna:run`
2. Provide run_id from Walkthrough 1
3. When asked what to run → reply: `all remaining stages`
4. When shown command → reply: `yes`

**Pass criteria:**
- Nextflow executes successfully (exit 0)
- `results/{run_id}/pipeline_state.json` is updated to `"completed_stages": ["qc", "denoise", "classify", "diversity", "association"]`
- Agent reports stage completions as they happen
- Agent ends with instruction to invoke `/edna:interpret`

Note: This walkthrough requires the full pipeline environment (all pixi envs) to be functional. If any stage fails, verify the failure handling in Walkthrough 6.

---

## Walkthrough 6 — Run: failure handling

**Setup:** Modify `params.json` to set an invalid primer sequence (`primers_fwd: "ZZZZZZZZ"`) that guarantees QC will fail.

**Script:**

1. Invoke `/edna:run`
2. Provide run_id
3. Confirm the command

**Pass criteria:**
- Agent detects the QC failure (non-zero exit or empty trimmed output)
- Agent extracts relevant log excerpt and explains the likely cause
- Agent offers three options: retry, skip, abort
- `pipeline_state.json` is NOT updated (QC not added to `completed_stages`)
- If scientist chooses retry with corrected primers: agent updates `params.json` and shows revised command

---

## Walkthrough 7 — Interpret: structured report from completed run

**Setup:** A completed run with all 5 stages in `completed_stages`. Use the outputs from Walkthrough 5 or point to pre-built fixtures.

**Script:**

1. Invoke `/edna:interpret`
2. Provide the run_id
3. When asked to proceed despite any anomalies (if flagged) → reply: `yes`

**Pass criteria:**
- `results/{run_id}/report.md` is created with all 7 sections (Run Summary, QC Summary, ASV Overview, Alpha Diversity, Beta Diversity, Differential Abundance, Caveats)
- No section is silently empty — if data is unavailable, section says so explicitly
- Narrative summary (2–3 paragraphs) is appended and printed to terminal
- Agent enters Q&A mode after the report

---

## Walkthrough 8 — Interpret: Q&A responds to 4 standard questions

**Setup:** Same as Walkthrough 7. Continue in Q&A mode after the report is written.

**Questions to ask:**

1. "Which taxa drive the separation between treatment and control groups?"
2. "Is sample1 a problem — it seems to have fewer reads?"
3. "What functional roles do the dominant bacterial genera likely have?"
4. "Are there any taxa that might indicate contamination?"

**Pass criteria for each:**
1. Agent reads `diversity/beta/` output and names specific taxa or notes the data is unavailable
2. Agent reads QC output files to give actual read counts for sample1, not a generic answer
3. Agent names the dominant genera from the taxonomy file and provides functional context appropriate to 16S
4. Agent checks decontam output and reports what was flagged (or confirms no flagged taxa)

---

## Fixture reference

Shared `pipeline_state.json` fixtures are in `tests/fixtures/`:

| File | Pipeline | Stages complete |
|------|----------|-----------------|
| `pipeline_state_16s_intake.json` | nf-edna-16s | none (intake only) |
| `pipeline_state_16s_qc.json` | nf-edna-16s | qc |
| `pipeline_state_16s_classify.json` | nf-edna-16s | qc, denoise, classify |
| `pipeline_state_16s_full.json` | nf-edna-16s | all 5 stages |
| `pipeline_state_euk_intake.json` | nf-edna-euk | none (intake only) |
| `pipeline_state_euk_full.json` | nf-edna-euk | all 5 stages |
