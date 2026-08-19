---
name: reference-db-preflight
description: Preflight validation for the reference-db sub-skill. Verifies (1) marker confirmed (16S/18S-V9/COI/12S), (2) disk space (≥ 5 GB), (3) Internet connectivity to canonical URL (HEAD request), (4) asset directory writable, (5) license accepted for the chosen reference, (6) if training required — DECIPHER + rentrez available. Produces a GO / GO-WITH-WARNINGS / NO-GO verdict gate before any download command is invoked.
version: 1.1.4
updated: "2026-08-19"
triggers:
  - "reference-db preflight"
  - "validate reference DB download"
  - "check disk for reference"
  - "verify reference URL"
requires:
  - "curl (for HEAD requests)"
  - "Internet access to one of: drive.google.com, github.com, zenodo.org, ftp.arb-silva.de, www.reference-midori.info, www.boldsystems.org"
  - "pixi (for env inspection)"
  - "R ≥ 4.2 (for DECIPHER check)"
---

# Sub-Skill: reference-db-preflight

## Audience

This sub-skill serves two simultaneous audiences:

1. **AI Coding Agents** — invoked by the parent `reference-db` orchestrator or directly. The agent must run all 6 stop points in order, write `preflight.md` + `preflight_evidence.json` + `preflight_verdict.txt`, and gate the run sub-skill on the verdict.
2. **Human eDNA scientists** — read this document to understand what validation runs before a reference download starts.

## When to Use

Use this sub-skill **always** before invoking `run/reference-db-run`. Its verdict is the gate that prevents downloading a 300 MB file that the user can't accept the license for, or that won't fit on the disk.

**Do NOT use this sub-skill** for: downloading raw sequencing reads (use `read-qc-trimming`); training a reference from scratch (use `idtaxa-training`); programmatic NCBI access (use `entrez-*` skills in the GPTomics bioSkills ecosystem).

## 0. Inputs / Outputs

### Inputs (gathered at invocation)

| Variable | Type | Required | Description |
| --- | --- | --- | --- |
| `marker` | enum | yes | `16s` / `18s-v9` / `coi` / `12s` |
| `reference_choice` | str | yes | URL or shorthand ID (e.g., `silva-138.2`, `pr2-5.1.0`, `mitofish-12s-nr`, `midori2-coi`, `bold-coi`) |
| `assets_dir` | path | yes | Where the downloaded file will be placed (typically `$HOME/data/nf-edna/assets/<marker>/`) |
| `train_required` | bool | no (auto-detected) | If true, the reference needs DECIPHER training (`idtaxa-training` Stage 1+2 chain) |

### Outputs

- `$RUN_DIR/preflight.md` — human-readable preflight report
- `$RUN_DIR/preflight_evidence.json` — machine-readable evidence (used by run sub-skill)
- `$RUN_DIR/preflight_verdict.txt` — single-word `GO` / `GO-WITH-WARNINGS` / `NO-GO`

## 0.5 Ask-User Stop Points

Each stop point follows the canonical **Evidence + Recommend + Options** pattern.

---

### SP1 — Marker confirmed

> **Evidence**: I will check `marker ∈ {16s, 18s-v9, coi, 12s}`.
- ✅ PASS if: marker is one of the four supported
- ❌ FAIL if: marker is something else (e.g., `its`, `23s`, custom)

> **Recommend**: PASS → proceed to SP2. FAIL → ask the user to choose from the supported markers.
>
> Options:
> - **(A) Use marker X (Recommended)**
> - (B) Use a different supported marker
> - (C) Abort — nf-edna doesn't support my marker

**Auto-pick when**: marker explicitly supplied and matches one of the four.

---

### SP2 — Disk space (≥ 5 GB at `assets_dir`)

> **Evidence**: I will `df -BG "$assets_dir"` and check `Avail ≥ 5000000` (5 GB).
- ✅ PASS if: ≥ 5 GB free
- ⚠️ WARN if: 2–5 GB free (small reference may still fit, but training may overflow)
- ❌ FAIL if: < 2 GB free

> **Recommend**: PASS → proceed to SP3. WARN → confirm. FAIL → ask the user to free space or pick a different location.
>
> Options:
> - **(A) 5 GB available, proceed (Recommended)**
> - (B) I'll free up more disk — wait and re-run
> - (C) Use a different `assets_dir` (larger disk)
> - (D) Abort

**Auto-pick when**: ≥ 5 GB free — auto-pick (A). 2–5 GB — surface the warning but proceed (GO-WITH-WARNINGS).

---

### SP3 — Internet connectivity to canonical URL

> **Evidence**: I will `curl -s -o /dev/null -w "%{http_code}" -I "<URL>"` (HEAD request).
- ✅ PASS if: HTTP 200 or 302 (redirect to download)
- ⚠️ WARN if: HTTP 429 (rate-limited) — retry once with backoff
- ❌ FAIL if: timeout, no response, or HTTP 5xx

> **Recommend**: PASS → proceed to SP4. WARN → retry. FAIL → ask the user to check the network or pick a mirror.
>
> Options:
> - **(A) URL is reachable, proceed (Recommended)**
> - (B) Retry the URL (in case of transient failure)
> - (C) Use a mirror / alternative URL
> - (D) Abort

**Auto-pick when**: HTTP 200 within 5 seconds — auto-pick (A).

---

### SP4 — Asset directory writable

> **Evidence**: I will `mkdir -p "$assets_dir/$marker" && touch "$assets_dir/$marker/.write_test"` and verify success.
- ✅ PASS if: directory created and writable
- ❌ FAIL if: cannot create directory or not writable

> **Recommend**: PASS → proceed to SP5. FAIL → ask for writable path.
>
> Options:
> - **(A) Directory writable, proceed (Recommended)**
> - (B) I'll give you a different path
> - (C) Abort

**Auto-pick when**: directory writable — auto-pick (A).

---

### SP5 — License accepted

> **Evidence**: I will check the reference's license from the catalog (CC-BY-4.0 / CC-BY-NC-4.0 / BOLD-terms / SILVA-dual-license).
- ✅ PASS if: license is CC-BY-4.0 or SILVA-dual (permissive)
- ⚠️ WARN if: license is CC-BY-NC-4.0 (non-commercial; commercial use restricted)
- ⚠️ WARN if: license is BOLD-terms (requires BOLD account + agreement)
- ❌ FAIL if: user explicitly rejects the license

> **Recommend**: PASS → proceed to SP6. WARN → confirm. FAIL → pick a different reference.
>
> Options:
> - **(A) License is acceptable, proceed (Recommended for permissive licenses)**
> - (B) I accept the non-commercial / BOLD restriction — proceed
> - (C) Use a different reference with a more permissive license
> - (D) Abort

**Auto-pick when**: license is CC-BY-4.0 or SILVA-dual — auto-pick (A). For CC-BY-NC or BOLD — surface the restriction and require explicit (B).

---

### SP6 — Training prerequisites (only if `train_required = true`)

> **Evidence**: I will run `pixi run --manifest-path env/classification/pixi.toml Rscript -e 'sapply(c("DECIPHER","Biostrings","rentrez","xml2","stringr"), function(p) requireNamespace(p, quietly=TRUE))'`.
- ✅ PASS if: all 5 packages return `TRUE`
- ❌ FAIL if: any package returns `FALSE`

> **Recommend**: PASS → proceed to verdict. FAIL → ask user to install missing packages.
>
> Options:
> - **(A) Install missing packages via pixi (Recommended)**
> - (B) Skip and use existing installation (not recommended)
> - (C) Abort

**Auto-skip when**: `train_required = false` (pre-trained DECIPHER file is being downloaded).

**Auto-pick when**: all 5 packages available — auto-pick (A) only if any are missing.

---

## 1. Verdict Gate

After all 6 stop points pass, emit the verdict:

```bash
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
| `curl: (6) Could not resolve host` | No DNS / firewall | Check `cat /etc/resolv.conf`; try a different network |
| `curl: (60) SSL certificate problem` | Outdated CA certs | `pixi run --manifest-path env/classification/pixi.toml python -m pip install --upgrade certifi` |
| `HTTP 403 Forbidden` on Google Drive | Google Drive blocks bots; download requires confirmation | Use `gdown` (pip) which handles the confirmation page, or pick a non-Drive alternative |
| `HTTP 429 Too Many Requests` | Rate-limited (Zenodo, NCBI eutils) | Retry with `sleep 60`; consider `idtaxa-training` `--batch_size 50` for NCBI |
| `Permission denied` on assets_dir | Wrong owner / mode | `chmod -R u+w "$assets_dir"`; or pick a different writable location |
| `pixi: r-decipher not found` | pixi env missing DECIPHER | `pixi add --manifest-path env/classification/pixi.toml bioconductor-decipher bioconductor-biostrings` |

## 3. Related skills

- **`reference-db`** (parent) — invokes this sub-skill from SP0
- **`run/reference-db-run`** (sibling) — consumes this sub-skill's verdict
- **`idtaxa-training`** (sibling) — invoked by the run sub-skill when `train_required = true`
- **`nf-edna/preflight/edna-intake`** — analogous preflight for nf-edna runs

## Verification

- [ ] All 6 stop points resolved to PASS or WARN (no FAIL left unresolved)
- [ ] `preflight_verdict.txt` exists and contains exactly `GO` or `GO-WITH-WARNINGS`
- [ ] `preflight_evidence.json` exists and has 6 entries under `.stop_points`
- [ ] `preflight.md` was written and is human-readable

## Invariants

- **Never** invoke `curl` / `wget` / `pixi run` for the reference download without first running this preflight and obtaining `GO` / `GO-WITH-WARNINGS`.
- **Never** modify a stop point's evidence-based thresholds without updating this SKILL.md and the run sub-skill's expectations.
- **Always** surface the license for the chosen reference; require explicit acceptance for CC-BY-NC or BOLD-restricted files.