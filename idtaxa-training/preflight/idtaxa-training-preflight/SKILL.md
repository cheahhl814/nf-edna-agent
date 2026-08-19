---
name: idtaxa-training-preflight
description: Preflight validation for the idtaxa-training sub-skill. Verifies (1) input FASTA exists and parses, (2) NCBI eutils connectivity (for rentrez-based stage 1), (3) DECIPHER availability in pixi env, (4) output paths are writable, (5) FASTA headers contain parsable accessions, (6) marker gene confirmed, (7) memory + batch size estimates. Produces a GO / GO-WITH-WARNINGS / NO-GO verdict gate before any stage script is invoked.
version: 1.1.4
updated: "2026-08-19"
triggers:
  - "idtaxa preflight"
  - "validate IDTAXA training inputs"
  - "check NCBI eutils"
  - "verify DECIPHER installation"
requires:
  - "pixi (for env inspection)"
  - "curl (for NCBI eutils connectivity test)"
  - "R ≥ 4.2 (for DECIPHER check)"
  - "Internet access (for SP2)"
---

# Sub-Skill: idtaxa-training-preflight

## Audience

This sub-skill serves two simultaneous audiences:

1. **AI Coding Agents** — invoked by the parent `idtaxa-training` orchestrator or directly. The agent must run all 7 stop points in order, write `preflight.md` + `preflight_evidence.json` + `preflight_verdict.txt`, and gate the run sub-skill on the verdict.
2. **Human bioinformaticians** — read this document to understand what validation runs before training starts.

## When to Use

Use this sub-skill **always** before invoking `run/idtaxa-training-run`. Its verdict is the gate that prevents cryptic `pixi run Rscript` errors.

**Do NOT use this sub-skill** for: validating raw sequencing reads (use `read-qc-trimming`); validating completed nf-edna runs (use `nf-edna`).

## 0. Inputs / Outputs

### Inputs (gathered at invocation)

| Variable | Type | Required | Description |
| --- | --- | --- | --- |
| `input_ncbi_fasta` | path | yes (unless skipping Stage 1) | Raw NCBI nucleotide FASTA |
| `decoded_fasta` | path | yes | Output path for DECIPHER-format FASTA |
| `model_rds` | path | yes | Output path for trained `.rds` |
| `species_list` | path | yes | Output path for species list |
| `query_fasta` | path | yes (for Stage 3) | Query sequences to classify (or "skip" to skip Stage 3) |
| `classification_tsv` | path | yes | Output path for classification TSV |
| `batch_size` | int | no (default 200) | Accessions per NCBI eutils request |
| `marker` | enum | yes | `16s` / `18s-v9` / `coi` / `12s` / `custom` |
| `taxo_levels` | list | no (default: 7 NCBI ranks) | Taxonomic ranks to include |

### Outputs

- `$RUN_DIR/preflight.md` — human-readable preflight report
- `$RUN_DIR/preflight_evidence.json` — machine-readable evidence (used by run sub-skill)
- `$RUN_DIR/preflight_verdict.txt` — single-word `GO` / `GO-WITH-WARNINGS` / `NO-GO`

## 0.5 Ask-User Stop Points

Each stop point follows the canonical **Evidence + Recommend + Options** pattern.

---

### SP1 — Reference FASTA exists + parses

> **Evidence**: I will check `test -f "$input_ncbi_fasta"` and parse the FASTA with `Biostrings::readDNAStringSet`.
- ✅ PASS if: file exists, ≥ 10 sequences, ≥ 100 bp average length
- ⚠️ WARN if: file exists, < 10 sequences (probably a test) OR ≥ 50,000 sequences (memory warning)
- ❌ FAIL if: file missing, or parse error, or all sequences < 50 bp

> **Recommend**: PASS → proceed to SP2. FAIL → ask the user for the correct FASTA path. WARN → confirm intent.
>
> Options:
> - **(A) File looks good, proceed (Recommended)**
> - (B) I'll give you a different path
> - (C) Abort

**Auto-pick when**: file exists, ≥ 100 sequences, all ≥ 100 bp — auto-pick (A).

---

### SP2 — NCBI eutils connectivity (only if Stage 1 will run)

> **Evidence**: I will `curl -s -o /dev/null -w "%{http_code}" https://eutils.ncbi.nlm.nih.gov/entrez/eutils/einfo.fcgi`.
- ✅ PASS if: HTTP 200
- ⚠️ WARN if: HTTP 429 (rate-limit) — retry once with backoff
- ❌ FAIL if: no response, timeout, HTTP 5xx

> **Recommend**: PASS → proceed to SP3. FAIL → ask the user whether to skip Stage 1 (provide DECIPHER-format FASTA directly) or abort.
>
> Options:
> - **(A) Internet works, proceed (Recommended)**
> - (B) Skip Stage 1, I'll provide DECIPHER-format FASTA
> - (C) Abort and check my network

**Auto-pick when**: HTTP 200 within 3 seconds — auto-pick (A). Auto-skip when: user supplied a DECIPHER-format FASTA (detected by `grep -l " Root;" "$input_ncbi_fasta"`).

---

### SP3 — DECIPHER package availability in pixi env

> **Evidence**: I will run `pixi run --manifest-path env/classification/pixi.toml Rscript -e 'library(DECIPHER); packageVersion("DECIPHER")'`.
- ✅ PASS if: DECIPHER ≥ 3.0, no errors
- ❌ FAIL if: package not installed, or `error: there is no package called 'DECIPHER'`

> **Recommend**: PASS → proceed to SP4. FAIL → ask user to install DECIPHER.
>
> Options:
> - **(A) Install DECIPHER via pixi (Recommended)**
> - (B) Skip and use existing installation (not recommended)
> - (C) Abort

**Auto-pick when**: DECIPHER ≥ 3.0 — auto-pick (A) only if `r-decipher` not in pixi.toml.

---

### SP4 — Output paths are writable

> **Evidence**: I will `touch "$decoded_fasta" "$model_rds" "$species_list" "$classification_tsv"` and verify success.
- ✅ PASS if: all 4 paths writable
- ❌ FAIL if: any path not writable (permission denied, missing parent dir)

> **Recommend**: PASS → proceed to SP5. FAIL → ask for writable paths.
>
> Options:
> - **(A) Paths look good, proceed (Recommended)**
> - (B) I'll give you different paths
> - (C) Abort

**Auto-pick when**: all paths writable — auto-pick (A).

---

### SP5 — FASTA headers contain parsable accessions

> **Evidence**: I will `grep -oE "^[A-Z]{1,2}[0-9]{5,9}(\.[0-9]+)?" "$input_ncbi_fasta" | head -1`.
- ✅ PASS if: ≥ 90% of headers match the NCBI accession regex
- ⚠️ WARN if: 50–90% match (some headers are misformatted — those will be skipped in Stage 1)
- ❌ FAIL if: < 50% match (headers are not NCBI accessions; this FASTA is not suitable)

> **Recommend**: PASS → proceed to SP6. WARN → confirm intent. FAIL → ask for a different FASTA.
>
> Options:
> - **(A) Headers look good, proceed (Recommended)**
> - (B) I'm OK with the unparseable headers being skipped
> - (C) Abort — I need a different FASTA

**Auto-pick when**: ≥ 90% match — auto-pick (A).

---

### SP6 — Marker gene confirmed

> **Evidence**: I will confirm `marker` was supplied and matches the FASTA content.
- ✅ PASS if: marker ∈ {`16s`, `18s-v9`, `coi`, `12s`, `custom`}
- ⚠️ WARN if: marker = `custom` (user is responsible for `--taxo_levels`)

> **Recommend**: PASS → proceed to SP7. WARN → confirm `custom` is intended.
>
> Options:
> - **(A) Marker is correct, proceed (Recommended)**
> - (B) Use a different marker

**Auto-pick when**: marker explicitly supplied — auto-pick (A).

---

### SP7 — Batch size + memory estimate

> **Evidence**: I will compute `n_batches = ceil(n_sequences / batch_size)` and `est_minutes = n_batches * 0.35`.
- ✅ PASS if: `n_batches < 500` AND `est_minutes < 30` (reasonable single-machine budget)
- ⚠️ WARN if: `500 ≤ n_batches < 2000` OR `30 ≤ est_minutes < 60`
- ❌ FAIL if: `n_batches ≥ 2000` OR `est_minutes ≥ 60`

> **Recommend**: PASS → proceed to verdict. WARN → confirm. FAIL → reduce `--batch_size`.
>
> Options:
> - **(A) Estimates look good, proceed (Recommended)**
> - (B) Use a smaller `--batch_size` (e.g., 50)
> - (C) Abort

**Auto-pick when**: `n_batches < 500` — auto-pick (A).

---

## 1. Verdict Gate

After all 7 stop points pass, emit the verdict:

```bash
# Count PASS / WARN / FAIL across SP1-SP7
PASS_COUNT=$(jq '.stop_points | map(select(.status == "PASS")) | length' "$RUN_DIR/preflight_evidence.json")
WARN_COUNT=$(jq '.stop_points | map(select(.status == "WARN")) | length' "$RUN_DIR/preflight_evidence.json")
FAIL_COUNT=$(jq '.stop_points | map(select(.status == "FAIL")) | length' "$RUN_DIR/preflight_evidence.json")

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "NO-GO" > "$RUN_DIR/preflight_verdict.txt"
elif [ "$WARN_COUNT" -gt 0 ]; then
    echo "GO-WITH-WARNINGS" > "$RUN_DIR/preflight_verdict.txt"
else
    echo "GO" > "$RUN_DIR/preflight_verdict.txt"
fi
```

**The run sub-skill will refuse to proceed unless `preflight_verdict.txt` contains `GO` or `GO-WITH-WARNINGS`.**

## 2. Troubleshooting — Signature library

| Signature in stderr / log | Likely cause | Suggested fix |
| --- | --- | --- |
| `eutils.ncbi.nlm.nih.gov: SSL certificate verify failed` | Outdated CA certs in the pixi env | Update ca-certificates: `pixi run --manifest-path env/classification/pixi.toml python -m pip install --upgrade certifi` |
| `Biostrings: too many sequences to load into memory (>1M)` | FASTA is too large for a single R session | Split FASTA by taxon group (e.g., per phylum) and run Stage 1 in chunks |
| `Error: --input_ncbi_fasta is required` (missing required arg) | preflight was invoked without all required paths | Re-invoke with all paths from §0 |
| `RuntimeError: pixi command not found` | pixi is not on PATH | `export PATH="$HOME/.pixi/bin:$PATH"` and re-run |

## 3. Related skills

- **`idtaxa-training`** (parent) — invokes this sub-skill from SP0
- **`run/idtaxa-training-run`** (sibling) — consumes this sub-skill's verdict
- **`nf-edna/preflight/edna-intake`** — similar stop-point structure for nf-edna runs

## Verification

- [ ] All 7 stop points resolved to PASS or WARN (no FAIL left unresolved)
- [ ] `preflight_verdict.txt` exists and contains exactly `GO` or `GO-WITH-WARNINGS`
- [ ] `preflight_evidence.json` exists and has 7 entries under `.stop_points`
- [ ] `preflight.md` was written and is human-readable

## Invariants

- **Never** run `bin/prepare_ncbi_fasta_for_idtaxa.R` or `bin/train_idtaxa_model.R` without first running this preflight and obtaining `GO` / `GO-WITH-WARNINGS`.
- **Never** modify a stop point's evidence-based thresholds without updating this SKILL.md and the run sub-skill's expectations.