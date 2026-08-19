---
name: idtaxa-training-run
description: >-
  Executes the 3-stage IDTAXA training workflow after preflight has passed
  (1) NCBI FASTA → DECIPHER-format headers via `prepare_ncbi_fasta_for_idtaxa.R`,
  (2) DECIPHER-format FASTA → trained `Taxa Train` model via `train_idtaxa_model.R`,
  (3) model + DECIPHER FASTA → species list + classification via `extract_scientific_names.jl`
  and the patched `idtaxa_rds.R`. Writes `run_summary.json` for downstream consumers.
version: 1.0.0
updated: "2026-08-19"
triggers:
  - "run IDTAXA training"
  - "execute IDTAXA stages"
  - "build DECIPHER classifier"
requires:
  - "Preflight verdict = GO or GO-WITH-WARNINGS (gates this sub-skill)"
  - "pixi (curl -fsSL https://pixi.sh/install.sh | bash) — runs the R + Julia scripts"
  - "R ≥ 4.2 with DECIPHER, Biostrings, rentrez"
  - "Julia ≥ 1.9 with ArgParse"
  - "Internet access (for Stage 1 if input is raw NCBI FASTA)"
---

# Sub-Skill: idtaxa-training-run

## Audience

This sub-skill serves two simultaneous audiences:

1. **AI Coding Agents** — invoked by the parent `idtaxa-training` orchestrator after preflight verdict is `GO` / `GO-WITH-WARNINGS`. The agent must run all 4 stop points in order, write `run_summary.json`, and not modify any artifact after it has been written.
2. **Human bioinformaticians** — read this document to understand the run phases and what to expect at each stage.

## When to Use

Use this sub-skill **after** `preflight/idtaxa-training-preflight` returns a `GO` or `GO-WITH-WARNINGS` verdict.

**Do NOT use this sub-skill** for: preflight validation (use `idtaxa-training-preflight`); production-scale eDNA classification (use `nf-edna`).

## 0. Inputs / Outputs

### Inputs (consumed from preflight evidence)

| Variable | Source | Description |
| --- | --- | --- |
| `input_ncbi_fasta` | preflight SP1 | Raw NCBI nucleotide FASTA (or DECIPHER-format, or skip Stage 1) |
| `decoded_fasta` | preflight SP4 | Output path for DECIPHER-format FASTA |
| `model_rds` | preflight SP4 | Output path for trained `.rds` |
| `species_list` | preflight SP4 | Output path for species list |
| `query_fasta` | preflight SP1 | Query sequences to classify (for Stage 3) |
| `classification_tsv` | preflight SP4 | Output path for classification TSV |
| `batch_size` | preflight SP7 | NCBI batch size |
| `taxo_levels` | preflight SP6 | Taxonomic ranks to include |
| `preflight_verdict` | preflight verdict file | Must be `GO` or `GO-WITH-WARNINGS` |

### Outputs

- `$RUN_DIR/decoded_fasta.fasta` — DECIPHER-format FASTA
- `$RUN_DIR/idtaxa_model.rds` — trained `Taxa Train` model (standard RDS, loadable via `readRDS()`)
- `$RUN_DIR/species_list.txt` — one scientific name per line
- `$RUN_DIR/classification.tsv` — per-sequence taxonomy + confidence per rank
- `$RUN_DIR/run_summary.json` — compact LLM-loadable summary
- `$RUN_DIR/pipeline_state.json` — run-state file consumed by debug sub-skill (future)

## 0.5 Ask-User Stop Points

Each stop point follows the canonical **Evidence + Recommend + Options** pattern.

---

### SP1 — Preflight verdict confirmed

> **Evidence**: `cat "$RUN_DIR/preflight_verdict.txt"` returns `GO` or `GO-WITH-WARNINGS`.
- ✅ PASS if: verdict is `GO` or `GO-WITH-WARNINGS`
- ❌ FAIL if: verdict is `NO-GO` or file missing

> **Recommend**: PASS → proceed to SP2.
>
> Options:
> - **(A) Preflight is GO, proceed (Recommended)**
> - (B) Re-run preflight (in case inputs changed)
> - (C) Abort

**Auto-pick when**: verdict = `GO` — auto-pick (A). If `GO-WITH-WARNINGS`, surface the warnings to the user and ask before proceeding.

---

### SP2 — Stage 1: NCBI FASTA → DECIPHER-format FASTA

> **Evidence**: I will run:
> ```bash
> pixi run --manifest-path env/classification/pixi.toml \
>   Rscript bin/prepare_ncbi_fasta_for_idtaxa.R \
>     --input_ncbi_fasta "$input_ncbi_fasta" \
>     --output_idtaxa_fasta "$decoded_fasta" \
>     --batch_size "$batch_size" \
>     --taxo_levels $taxo_levels
> ```
- ✅ PASS if: `decoded_fasta` exists, ≥ 80% of headers contain `;` separators
- ⚠️ WARN if: 50–80% headers contain `;` (some accessions failed taxonomy lookup)
- ❌ FAIL if: file not created, or < 50% headers valid

> **Recommend**: PASS → proceed to SP3. WARN → confirm. FAIL → re-run with smaller `--batch_size` or check NCBI connectivity.
>
> Options:
> - **(A) Stage 1 succeeded, proceed to Stage 2 (Recommended)**
> - (B) Stage 1 had warnings; re-run with `--batch_size 50` to reduce NCBI failures
> - (C) Abort

**Auto-skip when**: user supplied a DECIPHER-format FASTA directly (preflight detected ` Root;` in headers) — skip to SP3.

---

### SP3 — Stage 2: DECIPHER FASTA → trained model

> **Evidence**: I will run:
> ```bash
> pixi run --manifest-path env/classification/pixi.toml \
>   Rscript bin/train_idtaxa_model.R \
>     --input_reference_fasta "$decoded_fasta" \
>     --output_model "$model_rds" \
>     --max_group_size 10 \
>     --max_iterations 3 \
>     --taxo_levels $taxo_levels
> ```
- ✅ PASS if: `model_rds` exists, ≥ 100 sequences were used in training
- ⚠️ WARN if: < 100 sequences (small reference — model may be unreliable)
- ❌ FAIL if: file not created, or `error: no sequences remaining after pruning`

> **Recommend**: PASS → proceed to SP4. WARN → confirm. FAIL → re-run with `--max_group_size 5` or check DECIPHER FASTA headers.
>
> Options:
> - **(A) Stage 2 succeeded, proceed to Stage 3 (Recommended)**
> - (B) Stage 2 had warnings; I'm OK with a small reference
> - (C) Abort

**Auto-skip when**: user supplied a pre-trained `.rds` / `.rdata` model (skip Stage 2; use supplied model directly in Stage 3).

**Note**: Stage 2 is the longest stage — for a 50k-sequence reference, expect ~10–30 minutes of `DECIPHER::LearnTaxa()` runtime. The skill uses `pixi run` with all CPUs, but no `--resume` mechanism; if interrupted, restart from this stage.

---

### SP4 — Stage 3: species list + classification

> **Evidence**: I will run two commands:
> ```bash
> # Species list
> pixi run --manifest-path env/classification/pixi.toml \
>   julia bin/extract_scientific_names.jl \
>     --input_idtaxa_fasta "$decoded_fasta" \
>     --output_species_list "$species_list"
>
> # Classification
> pixi run --manifest-path env/classification/pixi.toml \
>   Rscript bin/idtaxa_rds.R \
>     --query_sequences "$query_fasta" \
>     --idtaxa_model "$model_rds" \
>     --output_classification "$classification_tsv" \
>     --output_confidence "${classification_tsv%.tsv}_confidence.tsv"
> ```
- ✅ PASS if: both files created; classification has ≥ 1 row
- ⚠️ WARN if: classification has 0 rows (no query sequences matched the trained taxa — usually means `--query_fasta` is wrong or empty)
- ❌ FAIL if: any script exited non-zero, or `idtaxa_rds.R` could not parse the model

> **Recommend**: PASS → write `run_summary.json`. WARN → verify `--query_fasta` and re-run. FAIL → re-run with verbose output.
>
> Options:
> - **(A) Stage 3 succeeded, write run_summary.json (Recommended)**
> - (B) Re-run with different `--query_fasta`
> - (C) Abort

**Auto-pick when**: classification has ≥ 1 row — auto-pick (A).

---

## 1. Run State

After all 4 stop points pass, append to `pipeline_state.json`:

```json
{
  "skill": "idtaxa-training",
  "version": "1.0.0",
  "completed_stages": ["stage1", "stage2", "stage3"],
  "last_stage": "stage3",
  "verdict": "GO",
  "outputs": {
    "decoded_fasta": "...",
    "model_rds": "...",
    "species_list": "...",
    "classification_tsv": "..."
  }
}
```

And write `run_summary.json`:

```json
{
  "skill": "idtaxa-training",
  "version": "1.0.0",
  "run_id": "...",
  "n_sequences_input": 52396,
  "n_sequences_decoded": 52396,
  "n_sequences_trained": 39886,
  "marker": "12s",
  "taxo_levels": ["superkingdom", "phylum", "class", "order", "family", "genus", "species"],
  "model_path": "$RUN_DIR/idtaxa_model.rds",
  "model_size_mb": 1.2,
  "n_species_in_model": 3214,
  "classification_n_rows": 0,
  "classification_n_unique_taxa": 0,
  "stage_timings_sec": {"stage1": 1200, "stage2": 1800, "stage3": 5},
  "completed_at": "2026-08-19T18:00:00Z"
}
```

## 2. Patched `bin/idtaxa_rds.R` — DECIPHER RDX3 + XZ support

The `bin/idtaxa_rds.R` script is **patched** (carried over from `nf-edna` v1.1.1) to load three model formats via magic-byte sniffing:

1. **Standard R RDS** (DECIPHER::IdTaxa output saved via `saveRDS`) — load via `readRDS()`
2. **DECIPHER RDX3 binary format** (the SILVA trainingFile, gzip- or XZ-compressed) — skip 5-byte `RDX3\n` header, then `unserialize()`, extract `obj$trainingSet`
3. **XZ-compressed standard RDS** (rare but supported) — decompress to temp file, re-detect

### Why this matters

DECIPHER writes trainingSet objects using a custom `Write()` method that prepends a 5-byte `RDX3\n` magic header followed by XDR-encoded S4 data. DECIPHER 3.x **does not export any loader** (no `trainingFile()` function). Base R `readRDS()` rejects this format with `"unknown input format"`.

Without this patch, users with pre-existing DECIPHER trainingFiles (e.g., SILVA `SILVA_SSU_r138.2.rdata`, 285 MB XZ-compressed) would need to either:
- Re-train the model from scratch (slow for large references)
- Manually decompress and parse the XDR stream

The patched loader makes this transparent. See `signature library Finding 7` in the upstream `nf-edna` for the full rationale.

### Auto-cached conversion

When the patched loader detects an RDX3 file, it also writes a converted `.converted.rds` next to the original — for faster future loads. This is automatic and requires no user action.

## 3. Troubleshooting — Signature library

| Signature in stderr / log | Likely cause | Suggested fix |
| --- | --- | --- |
| `cutadapt: adapter not found` | (n/a — this skill does not run cutadapt) | n/a |
| `pipeline produced ASVs but species assignments look like Bacteria/Archaea` | (n/a — this skill does not run ASV inference) | n/a |
| `NGmerge: paired reads failed merge` | (n/a — this skill operates on reference FASTA, not raw reads) | n/a |
| `LearnTaxa: No problem sequences remaining. Training converged.` | Training completed successfully | This is INFO, not an error. Move to SP4. |
| `No sequences left after removing problem sequences. Training stopped.` | All sequences were flagged as "problem" — header format issue | Re-run SP2 with `--allow_group_removal FALSE` to keep all sequences; or re-prepare FASTA |
| `LearnTaxa: problemSequences has N items remaining` (not converging) | `--max_iterations 3` is too few for this dataset | Re-run with `--max_iterations 10` (and a smaller `--max_group_size` if RAM-limited) |
| `idtaxa_rds.R: Loaded trainingSet; class: pairlist` | Bug — the patched RDX3 loader found `pairlist` instead of `Taxa Train` | Verify the file is RDX3 (magic `RDX3\n`) and the 5-byte header was skipped correctly |
| `Rscript: command not found` | pixi env not activated | Re-invoke `pixi run --manifest-path env/classification/pixi.toml ...` instead of bare `Rscript` |
| `Julia: command not found` | julia not in pixi env | `pixi add --manifest-path env/classification/pixi.toml julia` |

## 4. Related skills

- **`idtaxa-training`** (parent) — invokes this sub-skill from SP0
- **`preflight/idtaxa-training-preflight`** (prerequisite) — must pass verdict before this sub-skill runs
- **`nf-edna`** — downstream: consumes the trained `.rds` for production classification
- **`eDNA-visualize`** — sibling: produces figures from the classification TSV

## Verification

- [ ] `preflight_verdict.txt` was `GO` or `GO-WITH-WARNINGS` before any stage script was constructed (SP1).
- [ ] The exact `pixi run Rscript ...` command for each stage was shown to the scientist and explicitly confirmed (Step invariant).
- [ ] `pipeline_state.json.completed_stages` was extended only after a stage succeeded (Step invariant).
- [ ] `run_summary.json` was written at the end of the run.
- [ ] The trained `.rds` is loadable via `readRDS()` directly (NOT requiring the patched RDX3 loader).

## Invariants

- **Never** run a stage script without showing the full command first and waiting for explicit confirmation.
- **Never** modify a successfully-written artifact (`decoded_fasta`, `model_rds`, `species_list`, `classification_tsv`).
- **Never** skip the preflight sub-skill — its verdict gates this sub-skill.