---
name: edna-visualize-preflight
description: Preflight validation for the eDNA-visualize sub-skill. Verifies (1) all 4 count tables + 3 taxonomy tables + metadata file exist and parse, (2) sample IDs are consistent across all 8 inputs, (3) mia/miaViz/sechm/ComplexHeatmap packages are available in pixi env, (4) output directory is writable, (5) --group_by column exists in metadata. Produces a GO / GO-WITH-WARNINGS / NO-GO verdict gate before any plotting script is invoked.
version: 1.1.4
updated: "2026-08-19"
triggers:
  - "eDNA-visualize preflight"
  - "validate eDNA figure inputs"
  - "check mia packages"
  - "verify eDNA-visualize readiness"
requires:
  - "pixi (for env inspection)"
  - "R ≥ 4.2 (for mia check)"
---

# Sub-Skill: edna-visualize-preflight

## Audience

This sub-skill serves two simultaneous audiences:

1. **AI Coding Agents** — invoked by the parent `eDNA-visualize` orchestrator or directly. The agent must run all 5 stop points in order, write `preflight.md` + `preflight_evidence.json` + `preflight_verdict.txt`, and gate the run sub-skill on the verdict.
2. **Human bioinformaticians** — read this document to understand what validation runs before figures are produced.

## When to Use

Use this sub-skill **always** before invoking `run/edna-visualize-run`. Its verdict is the gate that prevents cryptic `Rscript` errors and silent zero-row outputs.

**Do NOT use this sub-skill** for: validating raw sequencing reads (use `read-qc-trimming`); validating completed nf-edna runs (use `nf-edna`).

## 0. Inputs / Outputs

### Inputs (gathered at invocation)

| Variable | Type | Required | Description |
| --- | --- | --- | --- |
| `input_asv_counts` | path | yes | ASV-level count table (TSV) |
| `input_phylum_counts` | path | yes | Phylum-level count table (TSV) |
| `input_family_counts` | path | yes | Family-level count table (TSV) |
| `input_genus_counts` | path | yes | Genus-level count table (TSV) |
| `input_phylum_taxonomy` | path | yes | Phylum-level taxonomy table (TSV) |
| `input_family_taxonomy` | path | yes | Family-level taxonomy table (TSV) |
| `input_genus_taxonomy` | path | yes | Genus-level taxonomy table (TSV) |
| `metadata_file` | path | yes | Sample metadata (TSV with `sample-id` column) |
| `output_dir` | path | yes | Output directory for figures + normalized TSVs |
| `group_by` | str | no | Metadata column for grouping replicates |

### Outputs

- `$RUN_DIR/preflight.md` — human-readable preflight report
- `$RUN_DIR/preflight_evidence.json` — machine-readable evidence (used by run sub-skill)
- `$RUN_DIR/preflight_verdict.txt` — single-word `GO` / `GO-WITH-WARNINGS` / `NO-GO`

## 0.5 Ask-User Stop Points

Each stop point follows the canonical **Evidence + Recommend + Options** pattern.

---

### SP1 — All 8 input tables exist + parse

> **Evidence**: I will check `test -f` for each of the 8 paths and parse each TSV with `data.table::fread(nrow=5)`.
- ✅ PASS if: all 8 paths exist, all parse as TSV with ≥ 1 data row
- ⚠️ WARN if: any file is empty or has only 1 row
- ❌ FAIL if: any file missing, or any parse error

> **Recommend**: PASS → proceed to SP2. FAIL → ask the user for the correct paths.
>
> Options:
> - **(A) All files look good, proceed (Recommended)**
> - (B) I'll give you different paths
> - (C) Abort

**Auto-pick when**: all 8 files exist and parse — auto-pick (A).

---

### SP2 — Sample IDs consistent across all 8 inputs

> **Evidence**: I will compute the intersection of sample IDs across the 4 count tables + metadata (taxonomy tables don't have sample IDs, but their row IDs are taxa, not samples — so the check is on count tables vs metadata only).
- ✅ PASS if: all sample-ID sets have non-empty intersection
- ⚠️ WARN if: intersection is small (e.g., 1–2 samples) — figures will be sparse
- ❌ FAIL if: intersection is empty (no common sample IDs between count tables and metadata)

> **Recommend**: PASS → proceed to SP3. WARN → confirm. FAIL → ask the user to align sample IDs.
>
> Options:
> - **(A) Sample IDs look good, proceed (Recommended)**
> - (B) I'll rename sample IDs to align
> - (C) Abort

**Auto-pick when**: intersection has ≥ 3 samples — auto-pick (A).

---

### SP3 — mia + miaViz + sechm + ComplexHeatmap packages available in pixi env

> **Evidence**: I will run `pixi run --manifest-path env/visualization/pixi.toml Rscript -e 'sapply(c("mia","miaViz","sechm","ComplexHeatmap","data.table","ggplot2","S4Vectors","argparse"), function(p) requireNamespace(p, quietly=TRUE))'`.
- ✅ PASS if: all 8 packages return `TRUE`
- ❌ FAIL if: any package returns `FALSE`

> **Recommend**: PASS → proceed to SP4. FAIL → ask user to install missing packages.
>
> Options:
> - **(A) Install missing packages via pixi (Recommended)**
> - (B) Skip and use existing installation (not recommended)
> - (C) Abort

**Auto-pick when**: all 8 packages available — auto-pick (A) only if any are missing.

---

### SP4 — Output directory is writable

> **Evidence**: I will `mkdir -p "$output_dir" && touch "$output_dir/.write_test"` and verify success.
- ✅ PASS if: directory created and writable
- ❌ FAIL if: cannot create directory or not writable

> **Recommend**: PASS → proceed to SP5. FAIL → ask for writable path.
>
> Options:
> - **(A) Output dir is writable, proceed (Recommended)**
> - (B) I'll give you a different output dir
> - (C) Abort

**Auto-pick when**: directory writable — auto-pick (A).

---

### SP5 — `--group_by` column exists in metadata (if specified)

> **Evidence**: I will `head -1 "$metadata_file"` and check if `--group_by` is in the header.
- ✅ PASS if: `--group_by` is unspecified, OR if specified and present in metadata header
- ❌ FAIL if: `--group_by` specified but not in metadata header
- ⚠️ (skipped if `--group_by` is unspecified)

> **Recommend**: PASS → proceed to verdict. FAIL → ask user to correct `--group_by`.
>
> Options:
> - **(A) Group-by column is valid, proceed (Recommended)**
> - (B) Use a different `--group_by` column
> - (C) Skip grouping (set `--group_by` to empty)

**Auto-pick when**: `--group_by` unspecified, or specified and present — auto-pick (A).

---

## 1. Verdict Gate

After all 5 stop points pass, emit the verdict:

```bash
# Count PASS / WARN / FAIL across SP1-SP5
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
| `Cannot open file` (during fread) | File missing or wrong path | Re-run with correct paths |
| `metadata header does not contain 'sample-id'` | Wrong metadata file supplied | Re-run with a metadata file that has a `sample-id` column |
| `pixi command not found` | pixi is not on PATH | `export PATH="$HOME/.pixi/bin:$PATH"` and re-run |
| `sechm requires ComplexHeatmap` | sechm and ComplexHeatmap versions are incompatible | Update both: `pixi run --manifest-path env/visualization/pixi.toml R -e 'BiocManager::install("ComplexHeatmap"); BiocManager::install("sechm")'` |
| `mia version < 1.0` (warning) | mia is too old for the current scripts | `pixi run --manifest-path env/visualization/pixi.toml R -e 'BiocManager::install("mia")'` |

## 3. Related skills

- **`eDNA-visualize`** (parent) — invokes this sub-skill from SP0
- **`run/edna-visualize-run`** (sibling) — consumes this sub-skill's verdict
- **`nf-edna/preflight/edna-intake`** — similar stop-point structure for nf-edna runs

## Verification

- [ ] All 5 stop points resolved to PASS or WARN (no FAIL left unresolved)
- [ ] `preflight_verdict.txt` exists and contains exactly `GO` or `GO-WITH-WARNINGS`
- [ ] `preflight_evidence.json` exists and has 5 entries under `.stop_points`
- [ ] `preflight.md` was written and is human-readable

## Invariants

- **Never** run `bin/normalize_abundance.R` or `bin/plot_*.R` without first running this preflight and obtaining `GO` / `GO-WITH-WARNINGS`.
- **Never** modify a stop point's evidence-based thresholds without updating this SKILL.md and the run sub-skill's expectations.