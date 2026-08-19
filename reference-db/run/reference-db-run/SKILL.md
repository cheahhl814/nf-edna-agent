---
name: reference-db-run
description: Executes the reference-db download + DECIPHER-training workflow after preflight has passed. Downloads the chosen reference (SILVA / PR2 / MIDORI2 / MitoFish / BOLD / custom) to the canonical assets directory, validates the file loads correctly (via the patched idtaxa_rds.R for DECIPHER pre-trained files; via FASTA parsing for raw references), and chains to idtaxa-training when the reference needs DECIPHER training. Writes run_summary.json for downstream consumers.
version: 1.1.4
updated: "2026-08-19"
triggers:
  - "run reference-db"
  - "execute reference DB download"
  - "fetch SILVA / PR2 / MIDORI2 / MitoFish / BOLD"
requires:
  - "Preflight verdict = GO or GO-WITH-WARNINGS (gates this sub-skill)"
  - "curl or wget (for downloads)"
  - "pixi (for the R validation script)"
  - "R ≥ 4.2 with DECIPHER, Biostrings (for validation)"
---

# Sub-Skill: reference-db-run

## Audience

This sub-skill serves two simultaneous audiences:

1. **AI Coding Agents** — invoked by the parent `reference-db` orchestrator after preflight verdict is `GO` / `GO-WITH-WARNINGS`. The agent must run all 4 stop points in order, write `run_summary.json`, and never modify an already-written artifact.
2. **Human eDNA scientists** — read this document to understand the download + training phases and what to expect at each step.

## When to Use

Use this sub-skill **after** `preflight/reference-db-preflight` returns a `GO` or `GO-WITH-WARNINGS` verdict.

**Do NOT use this sub-skill** for: preflight validation (use `reference-db-preflight`); production eDNA classification (use `nf-edna`).

## 0. Inputs / Outputs

### Inputs (consumed from preflight evidence)

| Variable | Source | Description |
| --- | --- | --- |
| `marker` | preflight SP1 | `16s` / `18s-v9` / `coi` / `12s` |
| `reference_choice` | preflight (catalog selection) | URL or shorthand ID |
| `url` | catalog | Canonical download URL |
| `sha256_expected` | catalog (if available) | SHA256 to verify (some URLs have it; SILVA-PR2-MIDORI2 don't always) |
| `compressed` | catalog (if applicable) | `xz` / `gzip` / `none` |
| `license` | catalog | License to surface (CC-BY-4.0 / CC-BY-NC-4.0 / BOLD-terms / SILVA-dual) |
| `train_required` | preflight (auto-detected) | If true, chain to `idtaxa-training` |
| `assets_dir` | preflight SP4 | Target directory |
| `preflight_verdict` | preflight verdict file | Must be `GO` or `GO-WITH-WARNINGS` |

### Outputs

- `$ASSETS_DIR/<marker>/<filename>` — the downloaded reference file(s)
- `$RUN_DIR/run_summary.json` — compact LLM-loadable summary
- `$RUN_DIR/pipeline_state.json` — run-state file consumed by debug sub-skill (future)
- `$RUN_DIR/preflight.md` + `$RUN_DIR/preflight_verdict.txt` — re-used from preflight

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

**Auto-pick when**: verdict = `GO` — auto-pick (A). If `GO-WITH-WARNINGS`, surface the warnings (especially the license) to the user and ask before proceeding.

---

### SP2 — Download + decompress

> **Evidence**: I will show the user the exact `curl`/`wget` command (URL, output path, resume flag, sha256 verify flag), wait for explicit confirmation, then run it.
>
> For XZ-compressed DECIPHER RDX3 files (e.g., SILVA `SILVA_SSU_r138.2.rdata`):
> ```bash
> curl -L -C - -o "$ASSETS_DIR/16s/SILVA_SSU_r138.2.rdata" \
>   "https://drive.google.com/uc?export=download&id=1w3wdSCpSihntWkbP_zvXz7r3s-tNB8DV"
> ```
> (or `gdown` for Google Drive)
>
> For gzip-compressed RDS files (e.g., PR2):
> ```bash
> curl -L -C - -o "$ASSETS_DIR/18s-v9/pr2_version_5.1.0_SSU.decipher.trained.rds" \
>   "https://github.com/pr2database/pr2database/releases/download/v5.1.0.0/pr2_version_5.1.0_SSU.decipher.trained.rds"
> ```
>
> For Zenodo (MitoFish via Mitohelper):
> ```bash
> curl -L -C - -o "$ASSETS_DIR/12s/mitofish.12S.Mar2025_NR.fasta" \
>   "<Zenodo record URL>"
> ```

- ✅ PASS if: file downloaded, size matches expected (within 5%)
- ⚠️ WARN if: file downloaded but sha256 mismatch (could be a different version)
- ❌ FAIL if: download failed (HTTP error, timeout, disk full)

> **Recommend**: PASS → proceed to SP3 (validate). WARN → re-download the correct file or accept the version mismatch. FAIL → retry with a different URL/mirror.
>
> Options:
> - **(A) Download succeeded, proceed to validation (Recommended)**
> - (B) File size or sha256 mismatched — investigate
> - (C) Use a different mirror / alternative URL
> - (D) Abort

**Auto-pick when**: file size within 5% of expected — auto-pick (A). Otherwise — surface the mismatch.

---

### SP3 — Validate file loads

> **Evidence**: I will run `bin/idtaxa_rds.R` (the patched nf-edna loader) for pre-trained DECIPHER files, or a Python/R script that parses the first 5 sequences for raw FASTAs.
>
> For DECIPHER RDX3 files (SILVA):
> ```bash
> pixi run --manifest-path env/classification/pixi.toml \
>   Rscript bin/idtaxa_rds.R \
>     --query_sequences /dev/null \
>     --idtaxa_model "$ASSETS_DIR/16s/SILVA_SSU_r138.2.rdata" \
>     --output_classification "$RUN_DIR/sanity_classification.tsv" \
>     --output_confidence "$RUN_DIR/sanity_confidence.tsv"
> ```
> (with a tiny dummy query — only the load matters)
>
> For gzip-compressed RDS files (PR2):
> ```bash
> Rscript -e "ts <- readRDS('$ASSETS_DIR/18s-v9/pr2_version_5.1.0_SSU.decipher.trained.rds'); cat('Loaded; class:', paste(class(ts), collapse=', '), '\n')"
> ```
>
> For raw FASTAs (MitoFish, MIDORI2):
> ```bash
> Rscript -e "library(Biostrings); dna <- readDNAStringSet('$ASSETS_DIR/12s/mitofish.12S.Mar2025_NR.fasta'); cat('Loaded', length(dna), 'sequences\n')"
> ```

- ✅ PASS if: file loads successfully (DECIPHER `Taxa Train` class or FASTA has ≥ 100 sequences)
- ⚠️ WARN if: file loads but has fewer sequences than expected (may indicate truncated download)
- ❌ FAIL if: load error, or file is corrupted

> **Recommend**: PASS → proceed to SP4. WARN → confirm. FAIL → re-download or pick a different file.
>
> Options:
> - **(A) File loads correctly, proceed (Recommended)**
> - (B) File has fewer sequences than expected — investigate
> - (C) Re-download
> - (D) Abort

**Auto-pick when**: file loads and has ≥ 100 sequences (or ≥ 1000 for DECIPHER training) — auto-pick (A).

---

### SP4 — DECIPHER training (only if `train_required = true`)

> **Evidence**: I will chain to `idtaxa-training`:
> - Stage 1: `pixi run --manifest-path env/classification/pixi.toml Rscript bin/prepare_ncbi_fasta_for_idtaxa.R --input_ncbi_fasta <raw_fasta> --output_idtaxa_fasta <decoded_fasta> --taxo_levels <...>`
> - Stage 2: `pixi run --manifest-path env/classification/pixi.toml Rscript bin/train_idtaxa_model.R --input_reference_fasta <decoded_fasta> --output_model <trained.rds> --max_group_size 5 --taxo_levels <...>`
> - Stage 3 (optional): `pixi run ... Rscript bin/idtaxa_rds.R --query_sequences <queries.fasta> --idtaxa_model <trained.rds>` for a sanity check.

- ✅ PASS if: `trained.rds` exists, ≥ 100 sequences were used in training
- ⚠️ WARN if: < 100 sequences (small reference — model may be unreliable)
- ❌ FAIL if: `train_idtaxa_model.R` errors (e.g., header format issue)

> **Recommend**: PASS → write `run_summary.json`. WARN → confirm. FAIL → re-run with smaller `--max_group_size` or fix the FASTA headers.
>
> Options:
> - **(A) Training succeeded, write run_summary.json (Recommended)**
> - (B) Re-run with `--max_group_size 5` (more species)
> - (C) Use the pre-trained DECIPHER file from the catalog (if available for this marker)
> - (D) Abort

**Auto-skip when**: `train_required = false` (pre-trained DECIPHER file downloaded).

**Auto-pick when**: training produces ≥ 100 sequences — auto-pick (A).

---

## 1. Run State

After all 4 stop points pass, append to `pipeline_state.json`:

```json
{
  "skill": "reference-db",
  "version": "1.0.0",
  "completed_stages": ["download", "validate", "train"],
  "last_stage": "train",
  "verdict": "GO",
  "outputs": {
    "reference_file": "<path to downloaded file>",
    "reference_size_mb": 299.0,
    "reference_sha256": "...",
    "trained_model": "<path to .rds, if training was done>",
    "license": "CC-BY-4.0"
  }
}
```

And write `run_summary.json`:

```json
{
  "skill": "reference-db",
  "version": "1.0.0",
  "run_id": "...",
  "marker": "16s",
  "reference_choice": "silva-138.2",
  "url": "https://drive.google.com/uc?export=download&id=1w3wdSCpSihntWkbP_zvXz7r3s-tNB8DV",
  "downloaded_file": "/home/user/data/nf-edna/assets/16s/SILVA_SSU_r138.2.rdata",
  "downloaded_size_mb": 299.0,
  "downloaded_sha256": "...",
  "format_detected": "rdx3_xz",
  "loaded_class": "Taxa, Train",
  "license": "SILVA dual-license",
  "train_required": false,
  "trained_model": null,
  "stage_timings_sec": {"download": 60, "validate": 2, "train": null},
  "completed_at": "2026-08-19T18:00:00Z"
}
```

## 2. Downloading from Google Drive (DECIPHER pre-trained files)

SILVA SSU r138.2 (and other DECIPHER trainingFiles) are hosted on Google Drive. Direct `curl` may fail with HTML "download quota exceeded" or "virus scan" pages. Recommended approaches:

```bash
# Option 1: pip install gdown (handles the confirmation page)
pip install gdown
gdown "1w3wdSCpSihntWkbP_zvXz7r3s-tNB8DV" \
  -O "$ASSETS_DIR/16s/SILVA_SSU_r138.2.rdata"

# Option 2: manual cookie confirmation
# (rarely works; gdown is preferred)
```

`gdown` is the canonical way to download Google Drive files programmatically. It's a Python pip package; not a conda package, so a separate `pip install` is required.

## 3. Troubleshooting — Signature library

| Signature in stderr / log | Likely cause | Suggested fix |
| --- | --- | --- |
| `curl: (6) Could not resolve host: drive.google.com` | DNS / firewall blocking Google Drive | Use `gdown` (which goes through Drive's download API), or pick a non-Drive alternative |
| `gdown: cannot retrieve file` | File ID is wrong, or file was made private | Verify the file ID by visiting the URL in a browser; check the DECIPHER Downloads page for the current ID |
| `gzip: not in gzip format` | Wrong file downloaded — DECIPHER trainingFiles are XZ-compressed | Re-download; do NOT pipe through `gzip -d` directly. The patched `bin/idtaxa_rds.R` handles XZ internally. |
| `unserialize(con): unknown input format` | The 5-byte RDX3 header wasn't skipped | Use the patched `bin/idtaxa_rds.R` (carried over from nf-edna v1.1.1) |
| `readRDS(): cannot open file` | Path is wrong or the download was incomplete | `ls -lh <path>`; re-run with `curl -C -` to resume |
| `MIDORI2 download: 403 Forbidden` | Session-based auth | Try the Zenodo mirror or contact maintainers |
| `BOLD download: account required` | BOLD Public Data Package requires account | Register at boldsystems.org OR use MIDORI2 (free alternative) |
| `train_idtaxa_model.R: No sequences left after removing problem sequences` | All sequences flagged as problematic | Check FASTA headers (must be NCBI accessions for `prepare_ncbi_fasta_for_idtaxa.R`); or set `--allow_group_removal FALSE` |
| `LearnTaxa: problemSequences has N items remaining` (stuck training) | `--max_iterations 3` is too few | Re-run with `--max_iterations 10` and `--max_group_size 5` |

## 4. Related skills

- **`reference-db`** (parent) — invokes this sub-skill from SP0
- **`preflight/reference-db-preflight`** (prerequisite) — must pass verdict before this sub-skill runs
- **`idtaxa-training`** (sibling) — invoked when the reference needs DECIPHER training (Stage 1: NCBI headers, Stage 2: LearnTaxa)
- **`nf-edna`** — downstream: consumes the reference for production classification

## Verification

- [ ] `preflight_verdict.txt` was `GO` or `GO-WITH-WARNINGS` before any download command was constructed (SP1).
- [ ] The exact `curl`/`wget`/`gdown` command for each step was shown to the user and explicitly confirmed (Step invariant).
- [ ] The downloaded file's size matches the expected size (within 5%).
- [ ] The file loads via the patched `bin/idtaxa_rds.R` (for DECIPHER pre-trained) or via `Biostrings::readDNAStringSet` (for raw FASTA).
- [ ] If training was required, the resulting `.rds` is loadable.
- [ ] `run_summary.json` was written at the end of the run.

## Invariants

- **Never** invoke a download command without showing the full URL and waiting for explicit confirmation.
- **Never** skip the preflight sub-skill — its verdict gates this sub-skill.
- **Always** verify the downloaded file's size + sha256 before proceeding to validation.
- **Always** use `gdown` (not `curl`) for Google Drive downloads.