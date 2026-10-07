#!/usr/bin/env python3
"""Structural smoke tests for the edna-agent meta-skill (v1.2.0).

Mirrors the bioinfo-skill-creator battle-test style: router wiring, sub-skill
frontmatter coherence, envelope-section presence, signature-library
completeness, recipe coverage, gitignore gate. 24 checks. Plain stdlib; run:
python3 test_smoke.py --offline
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RESULTS: list[tuple[str, bool, str]] = []
VERSION = "1.2.0"
SUBSKILLS = [
    "preflight/edna-intake",
    "run/edna-run",
    "interpret/edna-interpret",
]
AUX_SUBSKILLS = ["idtaxa-training", "reference-db", "edna-visualize"]


def check(name: str, cond: bool, detail: str = "") -> None:
    RESULTS.append((name, cond, detail))
    print(f"[{'PASS' if cond else 'FAIL'}] {name}" + (f"  -- {detail}" if detail and not cond else ""))


def frontmatter(path: Path) -> dict:
    text = path.read_text(errors="ignore")
    m = re.match(r"^---\n(.*?)\n---", text, re.DOTALL)
    if not m:
        return {}
    fm: dict = {}
    for line in m.group(1).splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            fm[k.strip()] = v.strip().strip("'\"")
    return fm


def has_sections(text: str, sections: list[str]) -> list[str]:
    missing = []
    for s in sections:
        if not re.search(re.escape(s), text):
            missing.append(s)
    return missing


def sig_library_rows(path: Path) -> int:
    text = path.read_text(errors="ignore")
    m = re.search(r"#+ *(?:Troubleshooting.*?|.*?Signature.librar\w*)", text)
    if not m:
        return 0
    tail = text[m.start():]
    rows = re.findall(r"^\|\s*`", tail, re.MULTILINE)
    return len(rows)


def main() -> int:
    print("== Master router ==")
    master_path = ROOT / "SKILL.md"
    mfm = frontmatter(master_path) if master_path.exists() else {}
    mtext = master_path.read_text(errors="ignore") if master_path.exists() else ""
    check("SKILL.md exists with frontmatter", bool(mfm))
    check("master name == edna-agent", mfm.get("name") == "edna-agent", str(mfm.get("name")))
    check(f"master version == {VERSION}", mfm.get("version") == VERSION, str(mfm.get("version")))
    check("master has updated + triggers", "updated" in mfm and "triggers" in mfm)
    check("master description present and non-trivial", len(str(mfm.get("description", ""))) >= 100)
    check("master is agent-driven (no workflow engine)", "agent-driven" in mtext)
    for probe in ("preflight/edna-intake", "run/edna-run", "interpret/edna-interpret"):
        check(f"master routes to {probe}", probe in mtext)
    check("master has an SP0 stop point", "SP0" in mtext)
    check("master documents marker presets", "params/16s.json" in mtext or "`16s.json`" in mtext)
    check("master documents handoff contract", "pipeline_state.json" in mtext and "run_summary.json" in mtext)

    print("== Sub-skill integrity ==")
    for sub in SUBSKILLS:
        sp = ROOT / sub / "SKILL.md"
        if not check(f"{sub}/SKILL.md exists", sp.exists()):
            continue
        fm = frontmatter(sp)
        check(f"{sub}/SKILL.md frontmatter coherence",
              fm.get("name") and fm.get("version") == VERSION and fm.get("updated") and
              "triggers" in sp.read_text(errors="ignore")[:1200])
        text = sp.read_text(errors="ignore")
        missing = has_sections(text, [
            "When to Use", "Inputs", "Outputs", "Signature librar", "Verification",
        ])
        check(f"{sub}/SKILL.md envelope sections present", not missing, "missing: " + ", ".join(missing))
        check(f"{sub}/SKILL.md has ask-user stop points", "SP1" in text)
        check(f"{sub}/SKILL.md signature library >= 3 rows", sig_library_rows(sp) >= 3,
              f"{sig_library_rows(sp)} rows")

    print("== Auxiliary sub-skills (version coherence only) ==")
    for aux in AUX_SUBSKILLS:
        sdir = ROOT / aux
        for sp in sorted(sdir.glob("**/SKILL.md")):
            if ".pixi" in str(sp):
                continue
            fm = frontmatter(sp)
            check(f"{sp.relative_to(ROOT)} version == {VERSION}",
                  fm.get("version") == VERSION, str(fm.get("version")))

    print("== Stage recipe coverage (agent-driven execution) ==")
    run_text = (ROOT / "run/edna-run/SKILL.md").read_text(errors="ignore")
    for tool in ("cutadapt", "fastqc", "NGmerge", "vsearch", "biom convert", "merge_tables.R",
                 "decontam.jl", "filter_table.jl", "idtaxa_rds.R", "filter_idtaxa_by_confidence.jl",
                 "agglomerate_data.R", "mafft", "fasttree", "root_tree.R", "alpha_diversity.R",
                 "beta_diversity.R", "community_typing.R", "differential_abundance.R",
                 "correlation_analysis.R"):
        check(f"run recipes cover {tool}", tool in run_text)
    check("run recipes wire the julia instantiate workaround",
          "Pkg.instantiate()" in run_text)
    check("run recipes forbid empty --num_clusters",
          'do NOT pass --num_clusters with an empty string' in run_text)
    check("run recipes use lowercase DAA rank", '"genus"' in run_text)
    check("run recipes include marker-sanity check",
          "Marker-sanity check" in run_text or "marker-sanity" in run_text.lower())
    for env in ("env/qc", "env/denoise", "env/decontam", "env/classification", "env/diversity", "env/association"):
        check(f"stage envs exist: {env}/pixi.toml", (ROOT / env / "pixi.toml").exists())

    print("== Binary scripts referenced by recipes ==")
    for script in ("bin/decontam.jl", "bin/filter_table.jl", "bin/merge_tables.R",
                   "bin/idtaxa_rds.R", "bin/filter_idtaxa_by_confidence.jl",
                   "bin/agglomerate_data.R", "bin/alpha_diversity.R", "bin/beta_diversity.R",
                   "bin/community_typing.R", "bin/differential_abundance.R",
                   "bin/correlation_analysis.R", "bin/root_tree.R",
                   "bin/summarise_run.py", "bin/skill-update-check.py"):
        check(f"{script} exists", (ROOT / script).exists())

    print("== Marker presets ==")
    for p in ("params/16s.json", "params/18s-v9.json", "params/coi.json", "params/12s.json"):
        ok = False
        detail = ""
        fp = ROOT / p
        if fp.exists():
            try:
                d = json.loads(fp.read_text())
                ok = "marker" in d and "kingdoms" in d and "daa_level" in d
            except Exception as exc:  # noqa: BLE001
                ok = False
                detail = str(exc)
        check(f"{p} parses with marker/kingdoms/daa_level", ok, detail)
    try:
        k = json.loads((ROOT / "params/12s.json").read_text())["kingdoms"].lower()
        check("12s preset kingdoms compatible with mitochondrial references",
              k in ("all", "mitochondria"), k)
    except Exception as exc:  # noqa: BLE001
        check("12s preset kingdoms compatible with mitochondrial references", False, str(exc))

    print("== Nextflow-free policy (no actionable usage in code blocks; historical prose allowed) ==")
    offenders = []
    for path in list(ROOT.glob("SKILL.md")) + list(ROOT.glob("*/**/SKILL.md")):
        t = path.read_text(errors="ignore")
        for block in re.findall(r"```.*?```", t, re.DOTALL):
            if re.search(r"nextflow run|nextflow\.config|-params-file|-stub-run", block, re.I):
                first = next((l for l in block.splitlines() if l.strip() and not l.strip().startswith("```")), "")
                offenders.append(f"{path.relative_to(ROOT)}: {first.strip()[:80]}")
    check("no actionable Nextflow commands in code blocks (v1.2.0 is agent-driven)", not offenders,
          "; ".join(offenders[:4]) if offenders else "")
    check("no runners/ directory", not (ROOT / "runners").exists())

    print("== Git hygiene gate ==")
    gi = ROOT / ".gitignore"
    gitext = gi.read_text() if gi.exists() else ""
    needed = ["battle-test-report.md", "battle-test_evidence.txt", "preflight.md",
              "preflight_evidence.txt", "results/", "assets/**"]
    missing = [n for n in needed if n not in gitext]
    check(".gitignore covers run artifacts + results/ + assets", not missing, "missing: " + ", ".join(missing))
    import subprocess
    try:
        tracked = subprocess.run(
            ["git", "ls-files", "--", "battle-test-report.md", "battle-test_evidence.txt",
             "preflight.md", "preflight_evidence.txt", "skill-built.md"],
            cwd=ROOT, capture_output=True, text=True).stdout.strip()
    except Exception:  # noqa: BLE001
        tracked = "?"
        pass
    check("no run artifacts tracked in git", tracked == "", str(tracked))

    print("== Historical-state compatibility ==")
    check("edna-run SP2 accepts v1.1.x state files (pipeline nf-edna)",
          '"nf-edna"' in run_text)

    print()
    passed = sum(1 for _, ok, _ in RESULTS if ok)
    failed = len(RESULTS) - passed
    print(f"== {passed}/{len(RESULTS)} checks passed, {failed} failed ==")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())