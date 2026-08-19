# Skill battle-test report

Skill:        nf-edna
Run:          /home/cheahhl814/claude_workspace/bioinformatics/AIx-BIO/skills/nf-edna
Generated:    2026-08-19
Meta-skill:   bioinfo-skill-creator v1.0.0 (used as reference pattern; not the build flow)

## Overall verdict

**PASS** ✅

All 38 structural smoke tests pass. The skill is BettaMt-compliant: every sub-skill has the canonical §0 Inputs/Outputs contract, §0.5 Ask-User Stop Points (Evidence + Recommend + Options), §Audience, §When/§Do-NOT-use, §Troubleshooting — Signature library, and the preflight sub-skill enforces the GO / GO-WITH-WARNINGS / NO-GO verdict gate that run/edna-run reads.

## Check matrix

| # | Check | Verdict | Notes |
|---|---|---|---|
| 1 | Frontmatter coherence | ✅ | 4 SKILL.md files (root + 3 sub-skills), all have name + description + version + updated + triggers; versions all v1.1.0 |
| 2 | Sub-skill contract wiring | ✅ | `preflight/edna-intake` → writes `pipeline_state.json` (with `verdict` field); `run/edna-run` → reads it + invokes `bin/summarise_run.py` → writes `run_summary.json`; `interpret/edna-interpret` → reads `run_summary.json` |
| 3 | **§0 Inputs/Outputs contract** | ✅ | All 3 sub-skills have explicit `## 0. Inputs / Outputs contract` sections with consumed-input + produced-output tables |
| 4 | **§0.5 Ask-User Stop Points** | ✅ | Master has 1 (SP0), preflight has 7 (SP1–SP7), run has 4 (SP1–SP4), interpret has 4 (SP1–SP4). Total: 16 SPs, every one in canonical `Evidence + Recommend + Options` format |
| 5 | **§Audience + §When/§Do-NOT-use** | ✅ | All 3 sub-skills have explicit Audience + When to Use + Do NOT use this skill sections |
| 6 | **§Troubleshooting — Signature library** | ✅ | preflight: 8 entries; run: 10 entries; interpret: 9 entries. Total: 27 signatures |
| 7 | **GO / GO-WITH-WARNINGS / NO-GO verdict gate** | ✅ | preflight computes 7 evidence items (E1–E7), writes `verdict` to `pipeline_state.json`; run/edna-run's SP1 enforces the gate (refuses on NO-GO, prompts on GO-WITH-WARNINGS, auto-proceeds on GO) |
| 8 | Signature-library completeness | ✅ | 27 entries across 3 sub-skills; well above canonical minimum of 3 per sub-skill |
| 9 | Docs-corpus freshness | ⚠️ | Not present. Recommended for v1.2.0: ingest tool docs for cutadapt, NGmerge, VSEARCH, IDTAXA, decontam, phyloseq, vegan, Nextflow DSL2. |
| 10 | Pixi parse (root) | ✅ | `pixi.toml` parses cleanly; v1.1.0; has `[project]`, `[dependencies]` (nextflow, python, julia, pandas, pyyaml, jsonschema), `[tasks]` (intake / run-stage / interpret / summarise), `[environments]` |
| 11 | Per-stage pixi envs preserved | ✅ | All 7 `env/{stage}/pixi.toml` files present and valid (use `[workspace]` shape — pixi monorepo feature) |
| 12 | Git hygiene | ✅ | `.git/` + `.gitignore` present; gitignore updated to cover `results/`, `work/`, `.nextflow.log*`, `*.fq.gz`, and the now-flattened `assets/` (was `nf-edna/assets/`) |
| 13 | Pipeline flatten | ✅ | `main.nf`, `nextflow.config`, `modules/`, `bin/`, `params/`, `env/` all at skill root; `nf-edna/` nested dir removed; `.claude/skills/` removed (wrong location for Pi) |
| 14 | Marker presets | ✅ | All 4 presets present: `params/16s.json`, `params/18s-v9.json`, `params/coi.json`, `params/12s.json` |
| 15 | Test smoke (`test_smoke.py`) | ✅ | 38 tests pass, 0 fail, 0 skip |

## v1.1.0 — what changed (vs v1.0.0)

| Change | v1.0.0 | v1.1.0 |
| --- | --- | --- |
| §0 Inputs/Outputs contract | absent | added to all 3 sub-skills + master |
| §0.5 Ask-User Stop Points | absent (master had prose SP0 only) | 16 SPs total: master SP0, preflight SP1–SP7, run SP1–SP4, interpret SP1–SP4. All in canonical Evidence + Recommend + Options format. |
| §Audience | absent | added to all 3 sub-skills |
| §When to Use / §Do NOT use this skill | absent | added to all 3 sub-skills |
| GO/GO-WITH-WARNINGS/NO-GO verdict gate | absent | added to preflight (computes 7 evidence items) and run (SP1 enforces the gate) |
| §Troubleshooting — Signature library | absent | 27 entries across 3 sub-skills |
| Auto-pick operating rule | absent | added to master §0.5 SP0 + every sub-skill §0.5 |
| Procedure bodies (Steps) | v1.0.0 | unchanged from v1.0.0 |
| Pipeline behavior | v1.0.0 | unchanged from v1.0.0 |

## Warnings

- **Docs-corpus not ingested** for the upstream tools (cutadapt, NGmerge, VSEARCH, IDTAXA, decontam, phyloseq, vegan, Nextflow DSL2). The `bioinfo-skill-creator` meta-skill would normally produce `docs-corpus/<tool>/README.md` + `.fingerprints` via its `build/skill-builder` sub-skill + `docs-ingest`. This manual migration skipped that phase. Recommended for v1.2.0.

## Recommendations

- **Next step**: `git add -A && git commit -m "v1.1.0: BettaMt canonical compliance + signature libraries"` and `git push -u origin master`. The skill is ready to ship as v1.1.0.
- **Optional (v1.2.0 backlog)**:
  - Use `docs-ingest` to build `docs-corpus/{cutadapt,ngmerge,vsearch,idtaxa,decontam,phyloseq,vegan,nextflow}/README.md`.
  - Deploy to `~/.pi/agent/skills/nf-edna/` — done as part of step 7 of the v1.1.0 workflow (md5-verified identical except `.git/` + `.gitignore`).

## Test command

```bash
cd /home/cheahhl814/claude_workspace/bioinformatics/AIx-BIO/skills/nf-edna
python3 test_smoke.py
# Expected: "OK" + "38 passed, 0 failed, 0 skipped (of 38)"
```

## Reproducibility

- Skill spec: `SKILL.md` (v1.1.0), `preflight/edna-intake/SKILL.md` (v1.1.0), `run/edna-run/SKILL.md` (v1.1.0), `interpret/edna-interpret/SKILL.md` (v1.1.0)
- Agent runtime: `pixi.toml` (v1.1.0)
- Pipeline: `main.nf`, `nextflow.config`, `modules/`, `bin/`, `params/`, `env/` (unchanged from v1.0.0)
- Smoke tests: `test_smoke.py` (38 tests)
- This report: `battle-test-report.md` (regenerable via `python3 test_smoke.py`)

## Handoff

Verdict is `PASS`. The skill is ready to commit and push as v1.1.0. Only one non-blocking warning (docs-corpus remains a v1.2.0 backlog item).