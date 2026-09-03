---
name: reference-db
description: Curated catalog of reference-database direct-download URLs for the four nf-edna markers (16S Bacteria/Archaea, 18S-V9 Eukaryota, COI Metazoa, 12S fish eDNA), with workflows for retrieving them and (when needed) training DECIPHER IDTAXA classifiers. Covers SILVA (16S/18S, DECIPHER pre-trained via Google Drive), PR2 (18S, DECIPHER pre-trained via GitHub releases), MIDORI2 (COI/12S mitochondrial, requires DECIPHER training), MitoFish (12S fish, raw FASTA + DECIPHER training), and BOLD (COI, requires DECIPHER training). Includes NCBI eutils access for custom FASTA construction (e.g., 12S Actinopterygii) via the existing `idtaxa-training` sub-skill. Mirrors the BettaMt ask-user-stop-points pattern. Use when the user asks to "download SILVA reference", "get PR2 database", "find MitoFish FASTA", "COI reference for metabarcoding", "where do I download 16S reference", "where do I download 18S reference", "where do I download 12S reference", "where do I download COI reference", "I need a reference for nf-edna", "what reference should I use for marker X", or "train a reference for marker X".
version: 1.1.4
updated: "2026-08-19"
triggers:
  - "download SILVA reference"
  - "get SILVA database"
  - "SILVA SSU 138 download"
  - "PR2 database download"
  - "PR2 SSU DECIPHER file"
  - "MitoFish 12S reference"
  - "MIDORI2 COI database"
  - "MIDORI download link"
  - "BOLD COI reference"
  - "where do I get the 16S reference"
  - "where do I get the 18S reference"
  - "where do I get the 12S reference"
  - "where do I get the COI reference"
  - "reference for nf-edna"
  - "what reference for marker X"
  - "train a reference for X"
  - "retrieve reference database"
  - "eDNA reference catalog"
requires:
  - "Internet access (for SILVA Google Drive, GitHub releases, Zenodo, ftp.arb-silva.de, NCBI eutils)"
  - "Disk space: ≥ 5 GB free for SILVA (~1 GB), PR2 (~500 MB), MIDORI2 (~600 MB), MitoFish (~600 MB)"
  - "Optional: DECIPHER + rentrez (for training markers without a pre-trained IDTAXA reference)"
  - "Optional: idtaxa-training sub-skill (in nf-edna) for custom-reference workflows"
---

# Sub-Skill: reference-db

> **v1.0.0.** Curated catalog of **direct download URLs** for the four nf-edna marker reference databases (SILVA 16S/18S, PR2 18S, MIDORI2/MitoFish 12S, MIDORI2/BOLD COI). For each marker, the catalog distinguishes:
>
> - **Pre-trained DECIPHER IDTAXA trainingFiles** (load directly via the patched `idtaxa_rds.R`): SILVA SSU r138.2, PR2 SSU v5.1.0, PR2 18S v4.13, UNITE 2025, Fungal LSU v11, RDP v18, GTDB r232, Contax v1, Warcup v2
> - **Raw reference databases** that need DECIPHER training: SILVA ARB files (NR99), PR2 flat files, MIDORI2 GenBank-derived files, MitoFish, BOLD
>
> For the pre-trained files, the run sub-skill handles the download + DECIPHER-format verification. For raw references, the run sub-skill chains to `idtaxa-training` (NCBI eutils → DECIPHER headers → train) to produce a custom-trained `.rds`.
>
> **This SKILL.md is a router.** It does not duplicate logic from the sub-skills. Its job is to ask: *what marker does the user need a reference for, and what download workflow matches?*

## Audience

This sub-skill serves two simultaneous audiences:

1. **AI Coding Agents** — triggered by the phrases above. The agent must follow the canonical evidence chain (Preflight → Run), respect the ask-user stop points, and never silently pick a reference DB — markers and user goals constrain the choice.
2. **Human eDNA scientists** — read this document as a curated catalog. The tables below give the canonical URL for each marker + DECIPHER-availability status + estimated size + license.

## When to Use This Skill

Use this sub-skill when you need to:

- Get a **reference database** for one of the four nf-edna markers (16S, 18S-V9, COI, 12S).
- Decide **which reference** to use for a specific marker (the catalog answers this directly).
- Download a **DECIPHER-pre-trained IDTAXA file** (SILVA, PR2, UNITE, RDP, GTDB, Contax, Warcup, Fungal LSU).
- **Train a custom IDTAXA model** from a raw reference (MIDORI2, BOLD, MitoFish, custom NCBI FASTA).

**Do NOT use this skill** if:

- You already have the reference file — invoke `idtaxa-training` or `nf-edna` directly.
- You want to run nf-edna end-to-end without thinking about references — `nf-edna` `preflight/edna-intake` will redirect you here if the model is missing.
- You want to access NCBI programmatically for non-reference data (use `read-qc-trimming` for read data; use `entrez-*` skills in the GPTomics bioSkills ecosystem).

## 0. Orchestrator — detect phase, route to the right sub-skill

This sub-skill is a **router**. It does not download anything itself. Its job is to ask: **"what marker, what reference format, and what workflow should we run?"**

### 0.1 Locate the run directory

By convention the agent writes handoff files to a run directory for the **reference-retrieval run under construction**. Default: a timestamped directory at the project root. Override with `RUN_DIR` env var.

```bash
# Example: fetching SILVA for a 16S run
RUN_DIR=<your-run-dir>/reference_db
```

### 0.2 Detect the user's phase

Try to detect automatically **before** asking:

```bash
# Phase detection ladder — first match wins
test -f "$RUN_DIR/reference_db_verdict.txt"  && PHASE="run-done"
test -f "$RUN_DIR/preflight_evidence.json"  && PHASE="run"
test -f "$RUN_DIR/preflight_verdict.txt"     && PHASE="run"
test -f "$RUN_DIR/preflight.md"             && PHASE="run"
: "${PHASE:=preflight}"
```

### 0.5 Master ask-user stop point (SP0)

> **Evidence**: I observed the user asked to download a reference for marker X. I checked the catalog in §1 below for marker X.
> **Recommend**: The catalog lists N options for marker X. The best default is the one marked "Pre-trained DECIPHER" because it requires zero training. If the user wants a different taxonomic scope (e.g., 16S fungi → UNITE instead of SILVA), surface the choice.
>
> Options:
> - **(A) Pick the catalog-recommended default (Recommended)** — SILVA for 16S, PR2 for 18S, MIDORI2 → DECIPHER training for COI, MitoFish → DECIPHER training for 12S
> - (B) Pick a different reference from the catalog
> - (C) I'll bring my own reference FASTA — go to `idtaxa-training`

**Auto-pick when**: marker is unambiguous and the catalog-recommended default is the only "Pre-trained DECIPHER" entry — auto-pick (A).

## 1. The Reference-Database Catalog

### 1.1 SILVA — 16S / 18S (Bacteria, Archaea, Eukaryota)

SILVA is the canonical ribosomal RNA reference for the small subunit (SSU = 16S/18S) and large subunit (LSU = 23S/28S). For nf-edna 16S and 18S-V9, use the **SSU** files.

| Variant | DECIPHER-ready? | URL | Size | Format | License |
|---|---|---|---|---|---|
| **SILVA SSU r138.2 (DECIPHER pre-trained, modified)** | ✅ **YES** (load via `bin/idtaxa_rds.R`) | `https://drive.google.com/file/d/1w3wdSCpSihntWkbP_zvXz7r3s-tNB8DV/view?usp=sharing` | 299 MB | RDX3 (XZ-compressed) | SILVA dual-license |
| SILVA SSU r138.2 NR99 (ARB format) | ❌ needs DECIPHER training | `https://www.arb-silva.de/fileadmin/silva_databases/current/Exports/SILVA_138.2_RData/SILVA_138.2_SSURef_NR99_03_07_24_opt.arb.gz` | 263 MB | ARB | SILVA dual-license |
| SILVA SSU r138.2 fasta + taxonomy | ❌ needs DECIPHER training | `https://www.arb-silva.de/fileadmin/silva_databases/current/Exports/SILVA_138.2_SSURef_tax_silva_trunc.fasta.gz` | 704 MB | fasta.gz + tax | SILVA dual-license |
| SILVA 138 trainset (DADA2-formatted, species) | ❌ needs DECIPHER training | `https://www.arb-silva.de/fileadmin/silva_databases/release_138_2/DADA2/1.36.0/SSU/silva_nr99_v138.2_toSpecies_trainset.fa.gz` | 134 MB | fasta.gz | SILVA dual-license |

**For nf-edna 16S / 18S**: use the **first row** (DECIPHER pre-trained). The user already has it at `assets/16s/SILVA_SSU_r138.2.rdata`.

### 1.2 PR2 — 18S (Protists, Eukaryota)

PR2 (Protist Ribosomal Reference database) is the canonical reference for protist 18S rRNA. It includes nucleus, plastid, mitochondrion, and a small bacterial set.

| Variant | DECIPHER-ready? | URL | Size | Format | License |
|---|---|---|---|---|---|
| **PR2 v5.1.0 SSU (DECIPHER pre-trained)** | ✅ **YES** | `https://github.com/pr2database/pr2database/releases/download/v5.1.0.0/pr2_version_5.1.0_SSU.decipher.trained.rds` | 412 MB | RDS (gzip) | CC-BY-4.0 |
| PR2 v4.13 18S (DECIPHER pre-trained, older) | ✅ **YES** | `https://drive.google.com/file/d/1pehefWEhm9Kpo1NlhDTqVjXEw4ZSYmT5/view?usp=sharing` (DECIPHER Downloads page) | 150 MB | RDX3 | CC-BY-4.0 |
| PR2 v5.1.0 SSU fasta (DADA2 / mothur / emu) | ❌ needs DECIPHER training | `https://github.com/pr2database/pr2database/releases/download/v5.1.0.0/pr2_version_5.1.0_SSU_dada2.fasta.gz` | 52 MB | fasta.gz | CC-BY-4.0 |
| PR2 v5.0.0 eKOI (COI extension, 2025) | ❌ needs DECIPHER training | `https://github.com/pr2database/pr2database/releases/tag/v5.1.1` (eKOI linked) | varies | xlsx + fasta | CC-BY-4.0 |
| PR2 R-package (Zenodo, for offline use) | n/a | `https://zenodo.org/records/15129782` (DOI: 10.5281/zenodo.15129782) | 30 MB | R-package | CC-BY-4.0 |

**For nf-edna 18S-V9**: use the **first row** (v5.1.0 SSU DECIPHER pre-trained).

### 1.3 MitoFish — 12S (Fish mitochondrial, MiFish-U primer amplicon)

MitoFish is the canonical fish mitochondrial genome reference, curated by the National Institute of Genetics (Japan) and Aomi Omae. The 12S fragment is the standard for MiFish-U eDNA metabarcoding.

| Variant | DECIPHER-ready? | URL | Size | Format | License |
|---|---|---|---|---|---|
| MitoFish 12S NR FASTA (Mar 2025) | ❌ **needs DECIPHER training** (raw FASTA + rentrez taxid enrichment via `idtaxa-training`) | `https://zenodo.org/records/17602902` (Mitohelper reference datasets) → `mitofish.12S.Mar2025_NR.fasta` | ~600 MB | fasta | CC-BY-4.0 |
| MitoFish complete mtDNA (v362) | ❌ needs DECIPHER training | `https://mitofish.aori.u-tokyo.ac.jp/species/list.html` (via `Mitohelper` Zenodo record) | varies | fasta | CC-BY-4.0 |
| 12S MiFish-U RDP classifier format | ✅ for RDP only (not DECIPHER) | `https://zenodo.org/records/4741464` | 2.8 KB | RDP classifier | CC-BY-4.0 |
| 12S MitoFish reference set (QIIME-compatible) | ❌ needs DECIPHER training | `https://github.com/aomlomics/Mitohelper` | varies | fasta.gz | CC-BY-4.0 |

**For nf-edna 12S**: there is **no pre-trained DECIPHER IDTAXA file for MitoFish**. Use the **first row** + chain to `idtaxa-training` Stage 1 (`prepare_ncbi_fasta_for_idtaxa.R`) to add DECIPHER headers via NCBI eutils, then Stage 2 (`train_idtaxa_model.R`) to train the model.

### 1.4 MIDORI2 — COI / 12S / mitochondrial (Metazoa)

MIDORI2 is the canonical reference for **metazoan mitochondrial genes**, built from GenBank release 265 (2025-03-08). It's the best free alternative to BOLD for COI when licensing prevents BOLD use.

| Variant | DECIPHER-ready? | URL | Size | Format | License |
|---|---|---|---|---|---|
| MIDORI2 UNIQ NUC GB265 COI BLAST | ❌ needs DECIPHER training | `https://www.reference-midori.info/download/Databases/GenBank265_2025-03-08/BLAST/uniq/MIDORI2_UNIQ_NUC_GB265_CO1_BLAST.zip` | varies | BLAST db | CC-BY-NC-4.0 |
| MIDORI2 UNIQ NUC GB265 12S BLAST | ❌ needs DECIPHER training | `https://www.reference-midori.info/download/Databases/GenBank265_2025-03-08/BLAST/uniq/MIDORI2_UNIQ_NUC_GB265_12S_BLAST.zip` | varies | BLAST db | CC-BY-NC-4.0 |
| MIDORI2 UNIQ NUC GB265 (all genes) | ❌ needs DECIPHER training | `https://www.reference-midori.info/download/Databases/GenBank265_2025-03-08/BLAST/uniq/` | varies | BLAST db | CC-BY-NC-4.0 |
| MIDORI2 download page | n/a | `https://www.reference-midori.info/download.php` | — | — | CC-BY-NC-4.0 |
| MIDORI2 homepage | n/a | `https://www.reference-midori.info/` | — | — | CC-BY-NC-4.0 |

**For nf-edna COI**: use **MIDORI2 COI** (free, CC-BY-NC, GenBank-curated) OR **BOLD** (gold standard, but requires BOLD data-portal access and is more restrictive). Both require DECIPHER training.

### 1.5 BOLD — COI (Metazoa, gold standard)

BOLD (Barcode of Life Data Systems) hosts the gold-standard COI reference library. Access requires a BOLD account and is licensed via the BOLD Data Packages.

| Variant | DECIPHER-ready? | URL | Size | Format | License |
|---|---|---|---|---|---|
| BOLD Public Data Package (latest snapshot) | ❌ needs DECIPHER training | `https://www.boldsystems.org/data/data-packages/` (latest) | 3 GB | tar.gz | BOLD terms |
| BOLD BOLDistilled (COI non-redundant) | � needs DECIPHER training | `https://boldsystems.org/data/BOLDistilled/` | varies | SINTAX | BOLD terms |
| BOLD BINs data packages | ❌ needs DECIPHER training | `https://bins.boldsystems.org/index.php/datapackages` | varies | tar.gz | BOLD terms |

**For nf-edna COI (gold standard)**: use the latest BOLD Public Data Package. Note: BOLD requires a registered account and license agreement. For a free alternative, use MIDORI2.

### 1.6 Other DECIPHER-pre-trained files (from DECIPHER Downloads)

The DECIPHER package maintains its own catalog of pre-trained trainingFiles (all on Google Drive). These are useful as references for nf-edna or any DECIPHER workflow:

| File | Use case | Size |
|---|---|---|
| **SILVA SSU r138.2 (modified)** | 16S / 18S | 299 MB |
| **PR2 18S v4.13** | 18S protists | 150 MB |
| **UNITE 2025 (unmodified)** | Fungal ITS | 120 MB |
| **Fungal LSU v11 (unmodified)** | Fungal LSU | 12 MB |
| **GTDB r232 (modified)** | 16S bacterial (newer than SILVA) | 88 MB |
| **RDP v18 (unmodified)** | 16S bacterial | 20 MB |
| **RDP v18 (modified)** | 16S bacterial | 18 MB |
| **Contax v1 (unmodified)** | Fungal ITS | 26 MB |
| **Warcup v2 (unmodified)** | Fungal ITS | 7 MB |

All at `https://decipher.codes/Downloads.html` (Google Drive links).

## 2. Decision Matrix

| nf-edna marker | Best pre-trained DECIPHER IDTAXA file | Alternative (free, GenBank-curated) | Notes |
|---|---|---|---|
| **16S** (Bacteria/Archaea) | SILVA SSU r138.2 (modified) — 299 MB | GTDB r232 (modified) — 88 MB | SILVA is more widely used; GTDB is more current taxonomy |
| **18S-V9** (Eukaryota) | PR2 v5.1.0 SSU — 412 MB | PR2 18S v4.13 — 150 MB | v5.1.0 is current; v4.13 is older DECIPHER format |
| **18S-V9** (protists specifically) | PR2 v5.1.0 SSU — 412 MB | SILVA SSU r138.2 — 299 MB | PR2 has better protist taxonomy |
| **12S** (fish eDNA) | **none** | MitoFish 12S NR + DECIPHER training | No pre-trained DECIPHER file exists for MitoFish |
| **12S** (general vertebrate) | **none** | MIDORI2 UNIQ 12S + DECIPHER training | MIDORI2 has all vertebrates, not just fish |
| **COI** (Metazoa) | **none** | MIDORI2 COI + DECIPHER training (CC-BY-NC, free) | BOLD COI + DECIPHER training (gold standard, requires BOLD account) |
| **ITS** (fungi, not in nf-edna currently) | UNITE 2025 (unmodified) — 120 MB | Contax v1 — 26 MB, Warcup v2 — 7 MB | nf-edna doesn't support ITS yet |

## 3. Where downloaded files go

By convention, the user places downloaded references in a directory structure that nf-edna can find:

```
$ASSETS_DIR/                    # typically /home/user/data/nf-edna/assets/
├── 16s/
│   ├── SILVA_SSU_r138.2.rdata     # 16S reference (DECIPHER pre-trained)
│   └── SILVA_SSU_r138.2.rdata.converted.rds  # auto-generated cache
├── 18s-v9/
│   └── pr2_version_5.1.0_SSU.decipher.trained.rds
├── 12s/
│   ├── mitofish_12S_Mar2025_NR.fasta  # raw NCBI-style FASTA
│   └── mitofish_12S_idtaxa.fasta      # DECIPHER-format FASTA (from idtaxa-training Stage 1)
│   └── mitofish_12S_idtaxa.rds        # trained model (from idtaxa-training Stage 2)
└── coi/
    ├── MIDORI2_CO1.fasta              # raw reference FASTA
    ├── MIDORI2_CO1_idtaxa.fasta       # DECIPHER-format FASTA
    └── MIDORI2_CO1_idtaxa.rds         # trained model
```

The run sub-skill will create these directories as needed.

## 4. Quick start

```bash
# 1. Preflight — confirms marker, picks reference, checks disk + connectivity
invoke_skill preflight/reference-db-preflight

# 2. Run — downloads (and trains if needed) the reference
invoke_skill run/reference-db-run

# Outputs:
#   reference_db_verdict.txt  — GO / GO-WITH-WARNINGS / NO-GO
#   preflight_evidence.json   — structured evidence for the run sub-skill
#   run_summary.json          — what was downloaded (URL, size, sha256, format)
#   <ASSETS_DIR>/<marker>/... — the reference file(s) in canonical location
```

## 5. Sub-skills

### Preflight (validate marker choice, disk, connectivity)

→ `preflight/reference-db-preflight/SKILL.md`

Validates:
- SP1 — Marker confirmed (16S / 18S-V9 / COI / 12S)
- SP2 — Disk space available (≥ 5 GB)
- SP3 — Internet connectivity to canonical URL (HEAD request)
- SP4 — Asset directory writable
- SP5 — License accepted for the chosen reference (some are CC-BY-NC, some BOLD-restricted)
- SP6 — If training required: DECIPHER + rentrez available in pixi env

Verdict: `GO` / `GO-WITH-WARNINGS` / `NO-GO`.

### Run (download + optionally train)

→ `run/reference-db-run/SKILL.md`

Phases:
- SP1 — Confirm preflight verdict is `GO` or `GO-WITH-WARNINGS`
- SP2 — **Download** the reference file (curl/wget with resume + sha256 verify)
- SP3 — **Decompress** if needed (XZ for SILVA RDX3, gzip for PR2 RDS)
- SP4 — **Validate** the file loads (via the patched `idtaxa_rds.R` for pre-trained files; via `parse(fasta_headers)` for raw FASTA)
- SP5 — **(if raw FASTA)** Chain to `idtaxa-training` Stages 1–2 to produce a DECIPHER `.rds`
- SP6 — Write `run_summary.json`

## 6. Where this fits in the wider skill graph

```
                 ┌──────────────────┐
                 │   reference-db   │  (this skill — catalog + download)
                 └────────┬─────────┘
                          │ DECIPHER `.rds` / raw FASTA + trained `.rds`
                          ▼
                 ┌──────────────────┐
                 │     nf-edna      │  ← main pipeline (uses the reference)
                 └──────────────────┘
                          ▲
                          │ (chains to)
                 ┌────────┴─────────┐
                 │ idtaxa-training  │  ← trains raw FASTA → DECIPHER `.rds`
                 └──────────────────┘
```

- **Upstream**: nothing (this is a discovery + retrieval skill).
- **Downstream**: `nf-edna` consumes the reference for production classification.
- **Parallel**: `idtaxa-training` is invoked when the chosen reference needs DECIPHER training.

## 7. Troubleshooting — Signature library

| Signature in stderr / log | Likely cause | Suggested fix |
| --- | --- | --- |
| `curl: (6) Could not resolve host: drive.google.com` | No DNS / firewall blocking Google Drive | DECIPHER trainingFiles are hosted on Google Drive. Use a proxy or pick a non-Drive alternative (e.g., PR2 GitHub releases instead of SILVA on Drive) |
| `gzip: not in gzip format` | Wrong file downloaded — DECIPHER trainingFiles are XZ-compressed RDX3 (not gzip) | Re-download; do NOT pipe through `gzip -d` directly. Use `unxz` first, then `unserialize` |
| `unserialize(con): unknown input format` | The 5-byte RDX3 header wasn't skipped | Use the patched `bin/idtaxa_rds.R` (carried over from nf-edna v1.1.1) — it auto-detects RDX3 + XZ |
| `readRDS(): cannot open file` | Path is wrong or the download was incomplete | Check `ls -lh <path>` matches the expected size; re-run with `-C -` to resume the download |
| `MIDORI2 download: 403 Forbidden` | The MIDORI2 site uses session-based auth; direct download links sometimes 403 | Try the Zenodo mirror (DOI 10.5281/zenodo.7560582) or contact the maintainers |
| `BOLD download: account required` | BOLD Public Data Package requires a registered BOLD account | Either register at boldsystems.org OR use MIDORI2 (free alternative) |
| `12S training: no sequences after pruning` | The MitoFish FASTA may have many short sequences that get filtered by `max_group_size` | Re-run with `--max_group_size 5` (smaller group cap) to retain more species |
| `pixi: r-decipher not found` | pixi env for classification missing DECIPHER | `pixi add --manifest-path env/classification/pixi.toml bioconductor-decipher bioconductor-biostrings` |

## 8. Related skills

- **idtaxa-training** (this repo: `idtaxa-training/`) — downstream: trains raw FASTA into DECIPHER `.rds` via NCBI eutils + DECIPHER::LearnTaxa
- **nf-edna** (`~/.pi/agent/skills/nf-edna/`) — downstream: uses the reference for production 16S/18S/COI/12S eDNA classification
- **edna-visualize** (`~/.pi/agent/skills/nf-edna/edna-visualize/`) — sibling: produces figures from classification outputs
- **edna-gbif-publish** (`~/.pi/agent/skills/edna-gbif-publish/`) — downstream: publishes classification results to GBIF
- **bioSkills database-access** (external: github.com/GPTomics/bioSkills/tree/main/database-access) — inspiration; covers NCBI/UniProt/Ensembl APIs (different scope — programmatic access vs reference DB retrieval)

## Verification

- [ ] `preflight/reference-db-preflight/SKILL.md` produces a `GO` / `GO-WITH-WARNINGS` verdict before any download command is invoked.
- [ ] The exact `curl`/`wget` command for the chosen URL was shown to the scientist and explicitly confirmed (Step invariant).
- [ ] The downloaded file's sha256 matches the value documented at the source (or was checked for non-zero size if no sha256 available).
- [ ] If the reference requires DECIPHER training, `idtaxa-training` was invoked and the resulting `.rds` is loadable.
- [ ] `run_summary.json` was written at the end of the run with the canonical URL, size, format, and license.

## Invariants

- **Never** invoke a download command without showing the full URL and waiting for explicit confirmation.
- **Never** skip the preflight sub-skill — its verdict gates the run sub-skill.
- **Always** verify the downloaded file's size + sha256 (when available) before proceeding to validation.
- **Always** surface the license for the chosen reference; require explicit acceptance for CC-BY-NC or BOLD-restricted files.
- **Always** check whether a pre-trained DECIPHER file exists for the chosen marker BEFORE recommending DECIPHER training.