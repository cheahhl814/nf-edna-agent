# Skill battle-test report

Skill:        nf-edna
Run:          /home/cheahhl814/claude_workspace/bioinformatics/AIx-BIO/skills/nf-edna
Generated:    2026-08-19
Meta-skill:   bioinfo-skill-creator v1.0.0 (used as reference pattern; not the build flow)

## Overall verdict

**PASS-WITH-WARNINGS** ⚠️

All structural smoke tests pass after the BettaMt restructure (43 file renames from flatten + 3 deletes from `.claude/skills/` removal + 5 new files for skill wrapper). One warning: docs-corpus + signature-library are not present (this skill was migrated manually, not built via the `bioinfo-skill-creator` meta-skill flow that produces those artifacts).

## Check matrix

| # | Check | Verdict | Notes |
|---|---|---|---|
| 1 | Frontmatter coherence | ✅ | 4 SKILL.md files (root + 3 sub-skills), all have name + description + version + updated + triggers; versions all v1.0.0 |
| 2 | Sub-skill contract wiring | ✅ | `preflight/edna-intake` → writes `pipeline_state.json`; `run/edna-run` → reads it + invokes `bin/summarise_run.py` → writes `run_summary.json`; `interpret/edna-interpret` → reads `run_summary.json` |
| 3 | Signature-library completeness | ⚠️ | Not present (3 sub-skill bodies are migrated from `.claude/skills/*.md` and don't yet have §Troubleshooting — Signature library sections). Recommended for v1.1.0. |
| 4 | Docs-corpus freshness | ⚠️ | Not present. Recommended for v1.1.0: ingest tool docs for cutadapt, NGmerge, VSEARCH, IDTAXA, decontam, phyloseq, vegan, Nextflow DSL2. |
| 5 | Pixi parse (root) | ✅ | `pixi.toml` parses cleanly; has `[project]`, `[dependencies]` (nextflow, python, julia, pandas, pyyaml, jsonschema), `[tasks]` (intake / run-stage / interpret / summarise), `[environments]` |
| 6 | Per-stage pixi envs preserved | ✅ | All 7 `env/{stage}/pixi.toml` files present and valid (use `[workspace]` shape — pixi monorepo feature) |
| 7 | Git hygiene | ✅ | `.git/` + `.gitignore` present; gitignore updated to cover `results/`, `work/`, `.nextflow.log*`, `*.fq.gz`, and the now-flattened `assets/` (was `nf-edna/assets/`) |
| 8 | Pipeline flatten | ✅ | `main.nf`, `nextflow.config`, `modules/`, `bin/`, `params/`, `env/` all at skill root; `nf-edna/` nested dir removed; `.claude/skills/` removed (wrong location for Pi) |
| 9 | Marker presets | ✅ | All 4 presets present: `params/16s.json`, `params/18s-v9.json`, `params/coi.json`, `params/12s.json` |
| 10 | Test smoke (`test_smoke.py`) | ✅ | 23 tests pass, 0 fail, 0 skip |

## Warnings

- **Signature-library not populated** for the 3 sub-skills. The sub-skill bodies are migrated verbatim from `.claude/skills/*.md` and don't yet include §Troubleshooting — Signature library sections. Recommended: add a v1.1.0 pass that introduces 3-5 entries per sub-skill (one per common failure mode).
- **Docs-corpus not ingested** for the upstream tools (cutadapt, NGmerge, VSEARCH, IDTAXA, decontam, phyloseq, vegan, Nextflow DSL2). The `bioinfo-skill-creator` meta-skill would normally produce `docs-corpus/<tool>/README.md` + `.fingerprints` via its `build/skill-builder` sub-skill + `docs-ingest`. This manual migration skipped that phase.

## Recommendations

- **Next step**: `git add -A && git commit -m "v1.0.0: battle-test + .gitignore coverage + test_smoke.py"` and `git push -u origin master`. The skill is ready to ship as v1.0.0.
- **Optional (v1.1.0 backlog)**:
  - Add §Troubleshooting — Signature library sections to each of `preflight/edna-intake`, `run/edna-run`, `interpret/edna-interpret` (3-5 entries each).
  - Use `docs-ingest` to build `docs-corpus/{cutadapt,ngmerge,vsearch,idtaxa,decontam,phyloseq,vegan,nextflow}/README.md`.
  - Deploy to `~/.pi/agent/skills/nf-edna/` — already done as part of step 6 of the restructure workflow (49 files, md5-verified identical except `.git/` + `.gitignore`).

## Test command

```bash
cd /home/cheahhl814/claude_workspace/bioinformatics/AIx-BIO/skills/nf-edna
python3 test_smoke.py
# Expected: "Ran 23 tests in ~0.02s OK" + "23 passed, 0 failed, 0 skipped (of 23)"
```

## Reproducibility

- params.json: not produced (manual migration, not meta-skill flow)
- preflight.md: not produced (manual migration)
- skill-built.md: not produced (manual migration)
- this report: `battle-test-report.md` (regenerable via `python3 test_smoke.py`)

## Handoff

Verdict is `PASS-WITH-WARNINGS`. The skill is ready to commit and push as v1.0.0. Warnings are non-blocking; they describe backlog items for v1.1.0.
