# Sub-Skill: reference-db

Curated catalog of **direct download URLs** for the four nf-edna marker reference databases (16S Bacteria/Archaea, 18S-V9 Eukaryota, COI Metazoa, 12S fish eDNA), with workflows for retrieving them and (when needed) training DECIPHER IDTAXA classifiers.

## What it does

For each marker, the catalog distinguishes:

- **Pre-trained DECIPHER IDTAXA trainingFiles** (load directly via the patched `bin/idtaxa_rds.R` from the nf-edna skill):
  - **SILVA SSU r138.2 (modified)** — 299 MB, RDX3 format, Google Drive
  - **PR2 v5.1.0 SSU** — 412 MB, RDS gzip format, GitHub releases
  - **PR2 18S v4.13** — 150 MB, RDX3 format, Google Drive (older version)
  - **UNITE 2025 (fungal ITS)** — 120 MB, RDX3 format, Google Drive
  - **GTDB r232, RDP v18, Contax v1, Warcup v2, Fungal LSU v11** — DECIPHER Downloads page

- **Raw reference databases** that need DECIPHER training (chains to `idtaxa-training`):
  - **SILVA SSU r138.2 NR99** — 263 MB ARB file (ftp.arb-silva.de)
  - **PR2 flat files** — fasta.gz + taxonomy TSV (GitHub releases)
  - **MIDORI2 (COI / 12S / mitochondrial)** — BLAST DB or FASTA (reference-midori.info)
  - **MitoFish (12S fish)** — Mitohelper Zenodo record (FASTA)
  - **BOLD COI** — Public Data Package, requires BOLD account (boldsystems.org)

For each reference, the catalog gives:
- DECIPHER-availability status
- Direct download URL
- Size + format
- License (CC-BY-4.0 / CC-BY-NC-4.0 / BOLD-terms / SILVA-dual)

## When to use

Use `reference-db` when you need to:

- Get a reference database for one of the four nf-edna markers (16S, 18S-V9, COI, 12S).
- Decide which reference to use for a specific marker (the catalog answers this directly).
- Download a DECIPHER-pre-trained IDTAXA file (SILVA, PR2, UNITE, RDP, GTDB, Contax, Warcup, Fungal LSU).
- Train a custom IDTAXA model from a raw reference (MIDORI2, BOLD, MitoFish, custom NCBI FASTA).

Do NOT use this skill if you already have the reference file — invoke `idtaxa-training` or `nf-edna` directly.

## Where it fits

```
   ┌──────────────────┐
   │   reference-db   │  (this skill — catalog + download)
   └────────┬─────────┘
            │ DECIPHER `.rds` / raw FASTA + trained `.rds`
            ▼
   ┌──────────────────┐
   │     nf-edna      │  ← main pipeline (uses the reference)
   └──────────────────�
            ▲
            │ (chains to)
   ┌────────┴─────────┐
   │ idtaxa-training  │  ← trains raw FASTA → DECIPHER `.rds`
   └──────────────────┘
```

## Decision matrix (quick reference)

| Marker | Best pre-trained DECIPHER | Alternative (free, GenBank-curated) |
|---|---|---|
| 16S | SILVA SSU r138.2 (modified) | GTDB r232 (modified) |
| 18S-V9 | PR2 v5.1.0 SSU | PR2 18S v4.13 |
| 12S | **none** | MitoFish 12S NR + DECIPHER training |
| COI | **none** | MIDORI2 COI + DECIPHER training (CC-BY-NC); or BOLD COI + DECIPHER training (requires account) |

## Quick start

```bash
# 1. Preflight — confirms marker, picks reference, checks disk + connectivity
invoke_skill preflight/reference-db-preflight

# 2. Run — downloads (and trains if needed) the reference
invoke_skill run/reference-db-run

# Outputs:
#   <ASSETS_DIR>/<marker>/<filename>  — the reference file
#   run_summary.json                  — what was downloaded
```

For Google Drive downloads (DECIPHER pre-trained files), `gdown` is required:

```bash
pip install gdown
```

## Structure

```
reference-db/
├── SKILL.md                                    # Router + curated catalog
├── README.md                                   # Human guide
└── pixi.toml                                   # Agent runtime deps
├── bin/                                        # (validation scripts, if any)
├── preflight/
│   └── reference-db-preflight/SKILL.md         # 6 stop points + verdict gate
└── run/
    └── reference-db-run/SKILL.md               # 4 stop points + state writes
```

## Related skills

- **idtaxa-training** (this repo: `idtaxa-training/`) — downstream: trains raw FASTA into DECIPHER `.rds` via NCBI eutils + DECIPHER::LearnTaxa
- **nf-edna** (`~/.pi/agent/skills/nf-edna/`) — downstream: uses the reference for production 16S/18S/COI/12S eDNA classification
- **edna-visualize** (`~/.pi/agent/skills/nf-edna/edna-visualize/`) — sibling: produces figures from classification outputs
- **edna-gbif-publish** (`~/.pi/agent/skills/edna-gbif-publish/`) — downstream: publishes classification results to GBIF
- **bioSkills database-access** (external: github.com/GPTomics/bioSkills/tree/main/database-access) — inspiration; covers NCBI/UniProt/Ensembl APIs

## Version

v1.0.0 — initial release (2026-08-19)

## Author

AIx-BIO (`cheahhl814`)