---
name: idtaxa-training
description: End-to-end training of DECIPHER IDTAXA taxonomic-classification models from raw reference sequences. Wraps three stages — (1) NCBI FASTA → DECIPHER-format headers via `prepare_ncbi_fasta_for_idtaxa.R`, (2) DECIPHER-format FASTA → trained `Taxa Train` model via `train_idtaxa_model.R`, (3) trained model → species list + IDTAXA classification via `extract_scientific_names.jl` and the patched `idtaxa_rds.R` (which loads standard RDS, gzipped RDS, AND XZ-/gzip-compressed DECIPHER RDX3 binary files). Mirrors the BettaMt ask-user-stop-points pattern and the canonical `nf-edna` evidence chain. Use when the user asks to "train an IDTAXA model", "build a DECIPHER reference for X", "I have a 16S/18S/COI/12S FASTA, train a classifier", "IDTAXA from NCBI FASTA", "prepare reference for taxonomic classification", or "I need a SILVA/PR2/MitoFish replacement trained on my own sequences". Pairs with `nf-edna` (downstream classification) and `eDNA-visualize` (downstream figures).
version: 1.1.4
updated: "2026-08-19"
triggers:
  - "train IDTAXA model"
  - "build DECIPHER reference"
  - "IDTAXA from NCBI"
  - "prepare DECIPHER FASTA"
  - "train classifier for 16S"
  - "train classifier for 18S"
  - "train classifier for COI"
  - "train classifier for 12S"
  - "taxonomic classifier training"
  - "DECIPHER LearnTaxa"
  - "reference database for eDNA"
  - "MiFish-U reference"
  - "SILVA replacement"
  - "PR2 reference"
  - "MitoFish reference"
  - "taxonomy header format"
requires:
  - "R ≥ 4.2 with DECIPHER, Biostrings, rentrez, xml2, stringr, argparse"
  - "Julia ≥ 1.9 with ArgParse"
  - "pixi (curl -fsSL https://pixi.sh/install.sh | bash) — manages per-stage tool envs under env/"
  - "Internet access to NCBI eutils (entrez_summary, entrez_fetch) for the FASTA-preparation stage"
---

# Sub-Skill: idtaxa-training

> **v1.0.0.** Wraps three end-to-end stages for training a DECIPHER IDTAXA classifier from raw reference sequences: (1) NCBI FASTA → DECIPHER-format headers, (2) DECIPHER-format FASTA → trained `Taxa Train` model, (3) trained model + DECIPHER FASTA → species list + IDTAXA classification. Includes a patched `bin/idtaxa_rds.R` (carried over from `nf-edna` v1.1.1) that auto-detects standard RDS, gzipped RDS, AND XZ-/gzip-compressed DECIPHER RDX3 binary format — so users can either train fresh models (standard RDS output via `train_idtaxa_model.R`) or load existing DECIPHER trainingFiles (e.g., SILVA `SILVA_SSU_r138.2.rdata`) without modification.
>
> **This SKILL.md is a router.** It does not duplicate logic from the sub-skills. Its job is to ask: *what stage is the user at, and which sub-skill should they invoke next?*

## Audience

This sub-skill serves two simultaneous audiences:

1. **AI Coding Agents** — triggered by the phrases above. The agent must follow the strict evidence chain (Preflight → Run), respect the ask-user stop points (SP1–SP7 in preflight, SP1–SP4 in run), and write the artifacts each sub-skill specifies.
2. **Human bioinformaticians** — read this document as a guide. The sections explain *why* each stage exists and what the trade-offs are.

## When to Use This Skill

Use this sub-skill when you need to:

- Train an IDTAXA model **from scratch** on a custom reference (own 16S/18S/COI/12S FASTA + taxonomy).
- Convert an **NCBI nucleotide FASTA** (e.g., `12S_Actinopterygii_ncbi.fasta`, 50k accessions) into DECIPHER training-ready headers (`>accession Root;superkingdom;phylum;...;species`).
- Load an **existing DECIPHER trainingFile** (e.g., SILVA `SILVA_SSU_r138.2.rdata`, PR2 `.rds`) and classify a query FASTA against it.
- Extract a **species name list** from a DECIPHER-formatted FASTA (for downstream GBIF occurrence lookup or `eDNA-gbif-publish`).

**Do NOT use this skill** if:

- You already have a working `.rds` model and just want to run eDNA classification end-to-end → use `nf-edna` directly.
- You want a fully-managed Nextflow pipeline (this skill is script-based, single-machine, no DSL2) → use `nf-edna`.
- You want to query an existing reference without modification → use `nf-edna` `classify.nf` with your model path.

## 0. Orchestrator — detect phase, route to the right sub-skill

This sub-skill is a **router**. It does not run the R/Julia scripts itself. Its job is to ask: **"what stage is the user at, and which sub-skill should they invoke next?"**

### 0.1 Locate the run directory

By convention the agent writes handoff files to a run directory for the **training run under construction**. Default: a timestamped directory at the project root. Override with `RUN_DIR` env var.

```bash
# Example: training a 12S MiFish-U classifier on 50k NCBI accessions
RUN_DIR=/home/cheahhl814/projects/my-12s-classifier/run
```

### 0.2 Detect the user's phase

Try to detect automatically **before** asking:

```bash
# Phase detection ladder — first match wins
test -f "$RUN_DIR/model.rds"              && PHASE="run-done"
test -f "$RUN_DIR/run_summary.json"        && PHASE="run-done"
test -f "$RUN_DIR/preflight_evidence.json" && PHASE="run"
test -f "$RUN_DIR/preflight_verdict.txt"   && PHASE="run"
test -f "$RUN_DIR/preflight.md"            && PHASE="run"
: "${PHASE:=preflight}"
```

If auto-detection is ambiguous, ask the user one short question (see **SP0** in §0.5):

> Are you starting a fresh IDTAXA training run, or continuing a previous one?
>
> - new run (no preflight yet)
> - preflight done; ready to run
> - Something failed and I need help debugging

### 0.5 Master ask-user stop point (SP0)

> **Evidence**: I observed `RUN_DIR = $RUN_DIR` and the phase-detection ladder returned `PHASE = $PHASE`.
> **Recommend**: `PHASE = preflight` if `$RUN_DIR/preflight.md` is absent, otherwise `PHASE = run`.
>
> Options:
> - **(A) Start preflight** (Recommended) — run `preflight/idtaxa-training-preflight/SKILL.md` first
> - (B) Skip preflight, run directly — risky; missing inputs (no FASTA, no internet, no DECIPHER) will surface as cryptic `pixi run Rscript` errors instead of structured diagnostics
> - (C) Debug a previous failure — invoke the run sub-skill with `--debug` flag

**Auto-pick when**: `$RUN_DIR/preflight.md` exists and is older than 24 h — auto-pick (A) "re-run preflight" to catch toolchain drift.

## 1. Inputs

- **Required inputs (gathered in preflight SP1–SP3)**:
  - `input_ncbi_fasta` — raw NCBI nucleotide FASTA (any marker; 16S / 18S-V9 / COI / 12S / custom)
  - OR a pre-existing **DECIPHER-format FASTA** (skips `prepare_ncbi_fasta_for_idtaxa.R`)
  - OR a pre-existing **DECIPHER trainingFile** (`.rdata` / `.rds` / XZ-compressed RDX3) (skips the training stage entirely)
  - Output paths for: DECIPHER-format FASTA, trained model `.rds`, species list
- **Optional inputs**:
  - `--batch_size` (default 200) — accessions per NCBI eutils request
  - `--taxo_levels` (default: 7 NCBI standard ranks) — taxonomic ranks to include in headers
  - `--max_group_size` (default 10) — DECIPHER training group-pruning cap
  - `--max_iterations` (default 3) — DECIPHER training iteration cap
  - `--orient` — strand-orient all sequences before training (improves consistency)

## 2. Outputs

| Artifact | Format | Producer sub-skill | Description |
| --- | --- | --- | --- |
| `decoded_fasta.fasta` | FASTA | `prepare_ncbi_fasta_for_idtaxa.R` (run SP2) | DECIPHER-format FASTA with `Root;...;species` headers |
| `idtaxa_model.rds` | RDS | `train_idtaxa_model.R` (run SP3) | Trained `Taxa Train` S4 object (loadable by `idtaxa_rds.R`) |
| `species_list.txt` | TXT | `extract_scientific_names.jl` (run SP4) | One scientific name per line (for GBIF lookup) |
| `classification.tsv` | TSV | `idtaxa_rds.R` (run SP4) | Per-sequence taxonomy assignment + confidence per rank |
| `run_summary.json` | JSON | this skill (run SP4) | Compact, LLM-loadable summary of the full run |

## 3. The 3-stage workflow

```
   ┌──────────────────────────────────────────┐
   │ Stage 1: NCBI FASTA → DECIPHER FASTA     │
   │ (prepare_ncbi_fasta_for_idtaxa.R)        │   ← requires Internet
   └────────────────────┬─────────────────────┘
                        │ DECIPHER-format FASTA
                        ▼
   ┌──────────────────────────────────────────┐
   │ Stage 2: DECIPHER FASTA → trained model  │
   │ (train_idtaxa_model.R)                   │   ← requires DECIPHER::LearnTaxa
   └────────────────────┬─────────────────────┘
                        │ .rds
                        ▼
   ┌──────────────────────────────────────────┐
   │ Stage 3: classification + species list   │
   │ (idtaxa_rds.R + extract_scientific_names.jl)
   └──────────────────────────────────────────┘
```

**Stage 1** is optional — skip if input is already DECIPHER-format.
**Stage 2** is optional — skip if a pre-trained `.rds` / `.rdata` model exists.
**Stage 3** is required.

## 4. Quick start

```bash
# 1. Preflight — validates FASTA, Internet access, DECIPHER availability
invoke_skill preflight/idtaxa-training-preflight
#    → produces $RUN_DIR/preflight.md + preflight_evidence.json

# 2. Run — stages 1-3 as needed
invoke_skill run/idtaxa-training-run
#    → produces $RUN_DIR/{decoded_fasta.fasta, idtaxa_model.rds, species_list.txt, classification.tsv, run_summary.json}
```

## 5. Sub-skills

### Preflight (validate inputs + toolchain)

→ `preflight/idtaxa-training-preflight/SKILL.md`

Validates:
- SP1 — Reference FASTA exists, parses, has ≥ 10 sequences (small test) or ≥ 100 (real training)
- SP2 — Internet access to `eutils.ncbi.nlm.nih.gov` (for `entrez_summary`, `entrez_fetch`)
- SP3 — DECIPHER package available in pixi env (`env/classification/pixi.toml`)
- SP4 — Output paths writable
- SP5 — NCBI FASTA headers contain parsable accessions (regex `^[A-Z]{1,2}\d{5,9}(\.\d+)?$`)
- SP6 — Marker gene confirmed (16S / 18S / COI / 12S — affects `--taxo_levels` defaults)
- SP7 — Batch size + memory estimate (50k accessions × 200 batch → ~250 batches, ~10 min)

Verdict: `GO` / `GO-WITH-WARNINGS` / `NO-GO`.

### Run (execute the 3 stages)

→ `run/idtaxa-training-run/SKILL.md`

Phases:
- SP1 — Confirm preflight verdict is `GO` or `GO-WITH-WARNINGS`
- SP2 — **Stage 1**: `pixi run --manifest-path env/classification/pixi.toml Rscript bin/prepare_ncbi_fasta_for_idtaxa.R ...`
- SP3 — **Stage 2**: `pixi run --manifest-path env/classification/pixi.toml Rscript bin/train_idtaxa_model.R ...`
- SP4 — **Stage 3**: `julia bin/extract_scientific_names.jl ...` + `pixi run ... Rscript bin/idtaxa_rds.R ...`
- SP5 — Write `run_summary.json` for downstream consumers

## 6. Where this fits in the wider skill graph

```
                 ┌──────────────────┐
                 │ idtaxa-training  │  (this skill)
                 └─────┬───────┬────┘
                       │       │
        trained .rds   │       │ DECIPHER FASTA + model
                       ▼       ▼
                 ┌──────────────────┐         ┌─────────────────┐
                 │     nf-edna      │ ──────▶ │ eDNA-visualize  │
                 │ (downstream      │         │ (publication    │
                 │  classification) │         │  figures)       │
                 └──────────────────┘         └─────────────────┘
```

- **Upstream**: requires raw reference FASTA (NCBI download, MitoFish export, custom reference).
- **Downstream**: `nf-edna` consumes the trained `.rds` for production classification; `eDNA-visualize` consumes the resulting classification tables for figures.
- **Parallel**: `eDNA-visualize` can also produce figures from any DECIPHER-format FASTA, regardless of whether `idtaxa-training` was used.

## 7. Patched `bin/idtaxa_rds.R` — DECIPHER RDX3 + XZ support

The `bin/idtaxa_rds.R` script is **patched** (carried over from `nf-edna` v1.1.1) to load three model formats via magic-byte sniffing:

1. **Standard R RDS** (DECIPHER::IdTaxa output saved via `saveRDS`) — load via `readRDS()`
2. **DECIPHER RDX3 binary format** (the SILVA trainingFile, gzip- or XZ-compressed) — skip 5-byte `RDX3\n` header, then `unserialize()`, extract `obj$trainingSet`
3. **XZ-compressed standard RDS** (rare but supported) — decompress to temp file, re-detect

This means users can either train fresh models (always written as standard RDS) or load existing DECIPHER trainingFiles (often RDX3) **without modification**.

See `run/idtaxa-training-run/SKILL.md` §Troubleshooting — Signature library for the full rationale (Finding 7 in the upstream nf-edna signature library).

## 8. Troubleshooting — Signature library

| Signature in stderr / log | Likely cause | Suggested fix |
| --- | --- | --- |
| `Error: ENTREZ summary returned empty` | NCBI eutils rate-limit, or transient server error | Reduce `--batch_size` to 100, add `Sys.sleep(1)` between batches |
| `Error in unserialize(con) : unknown input format` (RDX3 path) | The model file is corrupted, or the 5-byte RDX3 header was missed | Re-download the SILVA trainingFile; the patched `idtaxa_rds.R` already auto-detects RDX3 — ensure you are running the patched version |
| `LearnTaxa: No problem sequences remaining. Training converged.` | Training completed successfully | This is INFO, not an error. Move to Stage 3. |
| `No sequences left after removing problem sequences. Training stopped.` | All sequences were flagged as "problem" — likely header format issue | Re-run `prepare_ncbi_fasta_for_idtaxa.R` to regenerate headers, or set `--allow_group_removal FALSE` to keep all sequences |
| `R script: package 'DECIPHER' is not available` | pixi env for classification stage missing DECIPHER | Run `pixi add --manifest-path env/classification/pixi.toml r-decipher r-biostrings` |
| `Julia: Package ArgParse not found` (extract_scientific_names.jl) | Julia env missing ArgParse | Run `pixi run --manifest-path env/classification/pixi.toml julia -e 'using Pkg; Pkg.add("ArgParse")'` |
| `IDTAXA trainingSet is not class 'Taxa Train'` | Wrong model file passed to `idtaxa_rds.R` | Confirm the model was produced by `train_idtaxa_model.R` (writes via `saveRDS`) or a DECIPHER trainingFile (.rdata) |

## 9. Related skills

- **nf-edna** (`~/.pi/agent/skills/nf-edna/`) — downstream: uses the trained `.rds` for production 16S/18S/COI/12S eDNA classification via Nextflow
- **eDNA-visualize** (`~/.pi/agent/skills/eDNA-visualize/`) — sibling: produces publication-ready figures from classification tables
- **read-qc-trimming** (`~/.pi/agent/skills/read-qc-trimming/`) — upstream: pre-processes raw reads before classification
- **edna-gbif-publish** (`~/.pi/agent/skills/edna-gbif-publish/`) — downstream: publishes classification results to GBIF

## Verification

- [ ] `preflight/idtaxa-training-preflight/SKILL.md` produces a `GO` / `GO-WITH-WARNINGS` verdict before any stage script is invoked.
- [ ] The exact `pixi run Rscript ...` command for each stage was shown to the scientist and explicitly confirmed (Step invariant).
- [ ] `run_summary.json` was written at the end of the run with all 3 stages' outputs recorded.
- [ ] Trained `.rds` is loadable via `readRDS()` (NOT requiring the patched RDX3 loader).

## Invariants

- **Never** invoke a stage script without showing the full command first and waiting for explicit confirmation.
- **Never** skip the preflight sub-skill — its verdict gates the run sub-skill.
- **Always** verify the trained `.rds` is standard RDS format (loadable via `readRDS()` directly) — not RDX3 — so it can be used by downstream `nf-edna` without special handling.