# Sub-Skill: idtaxa-training

End-to-end training of **DECIPHER IDTAXA** taxonomic-classification models from raw reference sequences. Bridges the gap between raw NCBI FASTA downloads and a trained, ready-to-use classifier.

## What it does

Three end-to-end stages for training a DECIPHER IDTAXA classifier:

1. **NCBI FASTA → DECIPHER-format headers** via `bin/prepare_ncbi_fasta_for_idtaxa.R`
   - Reads raw NCBI nucleotide FASTA (16S / 18S-V9 / COI / 12S / custom marker)
   - Fetches taxids via NCBI eutils (`entrez_summary`, `entrez_fetch`)
   - Resolves lineages → writes DECIPHER-compatible FASTA with `>accession Root;superkingdom;phylum;...;species` headers
2. **DECIPHER-format FASTA → trained `Taxa Train` model** via `bin/train_idtaxa_model.R`
   - Iterative `DECIPHER::LearnTaxa()` training with group pruning
   - Handles binomial species, missing-rank placeholders, batch NCBI accessions
   - Saves via `saveRDS()` → standard RDS (loadable by downstream `nf-edna` without modification)
3. **Trained model + DECIPHER FASTA → species list + classification** via `bin/extract_scientific_names.jl` and `bin/idtaxa_rds.R`
   - Extracts one scientific name per sequence (for GBIF lookup)
   - Classifies a query FASTA against the trained model
   - `bin/idtaxa_rds.R` auto-detects 3 model formats: standard RDS, gzipped RDS, XZ-/gzip-compressed DECIPHER RDX3 binary (carried over from `nf-edna` v1.1.1)

## When to use

Use `idtaxa-training` when:

- You want to **train an IDTAXA model from scratch** on a custom reference (own 16S/18S/COI/12S FASTA + taxonomy).
- You have an **NCBI nucleotide FASTA** (e.g., `12S_Actinopterygii_ncbi.fasta`, 50k accessions) and need DECIPHER training-ready headers.
- You have an **existing DECIPHER trainingFile** (e.g., SILVA `SILVA_SSU_r138.2.rdata`, 285 MB XZ-compressed) and want to classify queries against it without retraining.
- You need a **species name list** from a DECIPHER-formatted FASTA (for downstream GBIF lookup or `eDNA-gbif-publish`).

Do NOT use this skill if you already have a working `.rds` model and just want to run eDNA classification end-to-end — use `nf-edna` directly.

## Where it fits

```
   ┌──────────────────┐
   │ idtaxa-training  │  (this skill)
   └─────┬───────┬────┘
         │       │
  .rds   │       │ DECIPHER FASTA + model
         ▼       ▼
   ┌──────────────────┐         ┌─────────────────┐
   │     nf-edna      │ ──────▶ │ eDNA-visualize  │
   │ (downstream      │         │ (publication    │
   │  classification) │         │  figures)       │
   └──────────────────┘         └─────────────────┘
```

## Quick start

```bash
# 1. Preflight — validates FASTA, Internet access, DECIPHER availability
invoke_skill preflight/idtaxa-training-preflight

# 2. Run — stages 1-3 as needed
invoke_skill run/idtaxa-training-run

# Outputs:
#   decoded_fasta.fasta  — DECIPHER-format FASTA
#   idtaxa_model.rds     — trained Taxa Train model (standard RDS)
#   species_list.txt     — one scientific name per line
#   classification.tsv   — per-sequence taxonomy + confidence per rank
#   run_summary.json     — compact LLM-loadable summary
```

## Structure

```
idtaxa-training/
├── SKILL.md                                   # Router
├── README.md                                  # Human guide
├── pixi.toml                                  # Agent runtime deps
├── test_smoke.py                              # 19 structural tests
├── bin/
│   ├── prepare_ncbi_fasta_for_idtaxa.R        # Stage 1
│   ├── train_idtaxa_model.R                   # Stage 2
│   ├── extract_scientific_names.jl            # Stage 3 (species list)
│   └── idtaxa_rds.R                           # Stage 3 (classification)
├── preflight/
│   └── idtaxa-training-preflight/SKILL.md     # 7 stop points + verdict gate
└── run/
    └── idtaxa-training-run/SKILL.md           # 4 stop points + state writes
```

## Patched `bin/idtaxa_rds.R` — DECIPHER RDX3 + XZ support

The `bin/idtaxa_rds.R` script is **patched** (carried over from `nf-edna` v1.1.1) to load three model formats via magic-byte sniffing:

1. **Standard R RDS** (DECIPHER::IdTaxa output saved via `saveRDS`) — load via `readRDS()`
2. **DECIPHER RDX3 binary format** (the SILVA trainingFile, gzip- or XZ-compressed) — skip 5-byte `RDX3\n` header, then `unserialize()`, extract `obj$trainingSet`
3. **XZ-compressed standard RDS** (rare but supported) — decompress to temp file, re-detect

This means users can either train fresh models (always written as standard RDS) or load existing DECIPHER trainingFiles (often RDX3) **without modification**.

## Related skills

- **nf-edna** (`~/.pi/agent/skills/nf-edna/`) — downstream: uses the trained `.rds` for production 16S/18S/COI/12S eDNA classification via Nextflow
- **eDNA-visualize** (`~/.pi/agent/skills/eDNA-visualize/`) — sibling: produces publication-ready figures from classification tables
- **read-qc-trimming** (`~/.pi/agent/skills/read-qc-trimming/`) — upstream: pre-processes raw reads before classification
- **edna-gbif-publish** (`~/.pi/agent/skills/edna-gbif-publish/`) — downstream: publishes classification results to GBIF

## Version

v1.0.0 — initial release (2026-08-19)

## Author

AIx-BIO (`cheahhl814`)