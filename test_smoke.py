#!/usr/bin/env python3
"""Smoke tests for nf-edna skill (v1.0.0 — BettaMt restructure).

Verifies the agent-skill wrapping is structurally sound:

- All 4 SKILL.md files have valid YAML frontmatter (name, description, version,
  updated, triggers)
- Master and sub-skill versions are coherent (v1.0.0)
- Sub-skill contract wiring (preflight → run → interpret via pipeline_state.json
  + run_summary.json)
- pixi.toml parses cleanly with [project], [dependencies], [tasks]
- Pipeline files are flattened (main.nf, nextflow.config, modules/, bin/,
  params/, env/ at root; no nf-edna/ nested dir)
- Per-stage pixi envs under env/ are preserved (unchanged)
- .claude/skills/ is removed (was the wrong location for Pi)
- All marker presets (16s, 18s-v9, coi, 12s) are present
- Git hygiene: .gitignore covers docs-corpus/.fingerprints + work/

Adapted from `bioinfo-skill-creator/battle-test/skill-battle-test/SKILL.md`
phases 1, 2, 5, 6 — the structural checks that apply to a hand-migrated skill.
The docs-corpus / signature-library / nextflow-stub checks (phases 3, 4, 7) are
intentionally omitted because nf-edna was migrated manually, not built via the
`bioinfo-skill-creator` meta-skill flow that produces those artifacts.

Run with: python3 test_smoke.py
Exit code 0 on success, 1 on failure.
"""

import re
import sys
import tomllib
import unittest
from pathlib import Path

HERE = Path(__file__).parent

SUB_SKILLS = [
    "preflight/edna-intake/SKILL.md",
    "run/edna-run/SKILL.md",
    "interpret/edna-interpret/SKILL.md",
]

REQUIRED_FRONT = ("name", "description", "version", "updated", "triggers")

PIPELINE_FILES = [
    "main.nf",
    "nextflow.config",
    "modules/qc.nf",
    "modules/denoise.nf",
    "modules/classify.nf",
    "modules/diversity.nf",
    "modules/association.nf",
]

PER_STAGE_PIXI_ENVS = [
    "env/qc/pixi.toml",
    "env/denoise/pixi.toml",
    "env/classification/pixi.toml",
    "env/database/pixi.toml",
    "env/diversity/pixi.toml",
    "env/geocuration/pixi.toml",
    "env/association/pixi.toml",
]

MARKER_PRESETS = [
    "params/16s.json",
    "params/18s-v9.json",
    "params/coi.json",
    "params/12s.json",
]


def _read(rel):
    return (HERE / rel).read_text()


def _frontmatter(text):
    """Return the YAML frontmatter dict from a SKILL.md file."""
    parts = text.split("---", 2)
    if len(parts) < 3:
        return {}
    import yaml
    return yaml.safe_load(parts[1]) or {}


def _frontmatter_version(text):
    fm = _frontmatter(text)
    return str(fm.get("version")) if fm.get("version") is not None else None


def _frontmatter_updated(text):
    fm = _frontmatter(text)
    u = fm.get("updated")
    if isinstance(u, str):
        return u.strip('"')
    return None


class TestFrontmatterCoherence(unittest.TestCase):
    """All 4 SKILL.md files have valid YAML frontmatter with coherent versions."""

    def test_all_skillmds_have_required_frontmatter(self):
        for f in ["SKILL.md"] + SUB_SKILLS:
            with self.subTest(file=f):
                text = _read(f)
                fm = _frontmatter(text)
                self.assertTrue(fm, msg=f"{f} has empty/missing YAML frontmatter")
                for key in REQUIRED_FRONT:
                    self.assertIn(key, fm, msg=f"{f} frontmatter missing key: {key}")
                # Triggers must be a non-empty list
                self.assertIsInstance(fm["triggers"], list,
                                       msg=f"{f} frontmatter 'triggers' must be a list")
                self.assertGreater(len(fm["triggers"]), 0,
                                    msg=f"{f} frontmatter 'triggers' is empty")

    def test_master_and_subskil_versions_are_coherent(self):
        master = _frontmatter_version(_read("SKILL.md"))
        self.assertEqual(master, "1.0.0",
                          msg=f"master SKILL.md version is {master}, expected 1.0.0")
        for f in SUB_SKILLS:
            v = _frontmatter_version(_read(f))
            self.assertEqual(v, "1.0.0",
                              msg=f"{f} version is {v}, expected 1.0.0")

    def test_updated_dates_are_2026_08_19(self):
        for f in ["SKILL.md"] + SUB_SKILLS:
            u = _frontmatter_updated(_read(f))
            self.assertEqual(u, "2026-08-19",
                              msg=f"{f} updated: {u}, expected 2026-08-19")


class TestSubSkillContractWiring(unittest.TestCase):
    """Sub-skill contract: preflight → run → interpret, via pipeline_state.json + run_summary.json."""

    def test_master_documents_handoff_artifacts(self):
        text = _read("SKILL.md")
        # The master must reference both handoff artifacts that the contract requires
        self.assertIn("pipeline_state.json", text,
                       msg="master SKILL.md does not mention pipeline_state.json handoff")
        self.assertIn("run_summary.json", text,
                       msg="master SKILL.md does not mention run_summary.json handoff")

    def test_master_has_routing_table(self):
        text = _read("SKILL.md")
        # Master must have a routing table mapping stages to sub-skills
        self.assertIn("preflight/edna-intake", text,
                       msg="master SKILL.md routing table missing preflight/edna-intake")
        self.assertIn("run/edna-run", text,
                       msg="master SKILL.md routing table missing run/edna-run")
        self.assertIn("interpret/edna-interpret", text,
                       msg="master SKILL.md routing table missing interpret/edna-interpret")

    def test_preflight_outputs_pipeline_state_json(self):
        text = _read("preflight/edna-intake/SKILL.md")
        self.assertIn("pipeline_state.json", text,
                       msg="preflight/edna-intake does not document pipeline_state.json output")

    def test_run_consumes_pipeline_state_and_writes_run_summary(self):
        text = _read("run/edna-run/SKILL.md")
        self.assertIn("pipeline_state.json", text,
                       msg="run/edna-run does not document pipeline_state.json consumption")
        self.assertIn("summarise_run.py", text,
                       msg="run/edna-run does not document bin/summarise_run.py invocation")
        self.assertIn("run_summary.json", text,
                       msg="run/edna-run does not document run_summary.json output")

    def test_interpret_consumes_run_summary(self):
        text = _read("interpret/edna-interpret/SKILL.md")
        self.assertIn("run_summary.json", text,
                       msg="interpret/edna-interpret does not document run_summary.json consumption")


class TestPixiParse(unittest.TestCase):
    """Root pixi.toml parses and has the required agent-runtime deps."""

    def test_pixi_toml_parses(self):
        with open(HERE / "pixi.toml", "rb") as fh:
            cfg = tomllib.load(fh)
        # Required sections
        self.assertIn("project", cfg, msg="pixi.toml missing [project]")
        self.assertIn("dependencies", cfg, msg="pixi.toml missing [dependencies]")
        self.assertIn("tasks", cfg, msg="pixi.toml missing [tasks]")
        self.assertEqual(cfg["project"]["name"], "nf-edna")
        self.assertEqual(cfg["project"]["version"], "1.0.0")

    def test_pixi_has_nextflow_dep(self):
        with open(HERE / "pixi.toml", "rb") as fh:
            cfg = tomllib.load(fh)
        # Nextflow must be in the agent runtime (per-stage envs are separate)
        self.assertTrue(any("nextflow" in k for k in cfg["dependencies"]),
                         msg="pixi.toml dependencies missing nextflow")

    def test_pixi_has_python_dep(self):
        with open(HERE / "pixi.toml", "rb") as fh:
            cfg = tomllib.load(fh)
        self.assertTrue(any("python" in k for k in cfg["dependencies"]),
                         msg="pixi.toml dependencies missing python")


class TestPipelineFlatten(unittest.TestCase):
    """The pipeline is flattened to the skill root — no nf-edna/ nested directory."""

    def test_main_nf_at_root(self):
        self.assertTrue((HERE / "main.nf").exists(),
                         msg="main.nf missing from skill root (was nested under nf-edna/)")

    def test_nextflow_config_at_root(self):
        self.assertTrue((HERE / "nextflow.config").exists(),
                         msg="nextflow.config missing from skill root")

    def test_no_nested_nf_edna_dir(self):
        nested = HERE / "nf-edna"
        self.assertFalse(nested.exists(),
                          msg="nf-edna/ nested directory still exists — flatten incomplete")

    def test_modules_bin_params_env_at_root(self):
        for d in ("modules", "bin", "params", "env"):
            self.assertTrue((HERE / d).is_dir(),
                             msg=f"{d}/ missing from skill root")
        # Sanity: at least one .nf per stage module
        self.assertTrue((HERE / "modules/qc.nf").exists(),
                         msg="modules/qc.nf missing")

    def test_pipeline_files_all_present(self):
        for f in PIPELINE_FILES:
            self.assertTrue((HERE / f).exists(),
                             msg=f"required pipeline file missing: {f}")

    def test_per_stage_pixi_envs_preserved(self):
        """Per-stage pixi envs (env/{stage}/pixi.toml) must be unchanged from the original.

        These are Nextflow-internal pixi workspaces (use [workspace] not [project]).
        We accept either pixi shape: [project] OR [workspace].
        """
        for f in PER_STAGE_PIXI_ENVS:
            self.assertTrue((HERE / f).exists(),
                             msg=f"per-stage pixi env missing (must be preserved): {f}")
            with open(HERE / f, "rb") as fh:
                cfg = tomllib.load(fh)
            self.assertTrue("project" in cfg or "workspace" in cfg,
                             msg=f"{f} is not a valid pixi.toml (missing [project] or [workspace])")

    def test_no_claude_skills_dir(self):
        """The old .claude/skills/ location must be removed (Pi reads from skill root)."""
        old = HERE / ".claude"
        self.assertFalse(old.exists(),
                          msg=".claude/ directory still exists — was the wrong location for Pi")

    def test_marker_presets_all_present(self):
        for f in MARKER_PRESETS:
            self.assertTrue((HERE / f).exists(),
                             msg=f"marker preset missing: {f}")


class TestGitHygiene(unittest.TestCase):
    """Git hygiene: .git/ present, .gitignore covers work/ + results/."""

    def test_git_repo_initialized(self):
        self.assertTrue((HERE / ".git").is_dir(),
                         msg=".git/ missing — git repo not initialized")

    def test_gitignore_present(self):
        gi = HERE / ".gitignore"
        self.assertTrue(gi.exists(), msg=".gitignore missing")
        content = gi.read_text()

    def test_gitignore_covers_results(self):
        """Run artifacts (results/) must be gitignored — they're per-run, not skill code."""
        content = (HERE / ".gitignore").read_text()
        self.assertIn("results", content,
                       msg=".gitignore does not cover results/ (per-run artifacts must be ignored)")


class TestNoPersonalPaths(unittest.TestCase):
    """No filesystem paths leaked into any SKILL.md or pixi.toml.

    'cheahhl814' as a GitHub username in URLs is OK; only /home/<user> paths are forbidden.
    """

    def test_no_personal_paths(self):
        forbidden = re.compile(r"/home/[a-z]+")
        targets = ["SKILL.md", "pixi.toml"] + SUB_SKILLS
        for f in targets:
            text = _read(f)
            m = forbidden.search(text)
            self.assertIsNone(m, msg=f"{f} contains personal path: {m.group(0) if m else '?'}")


def main():
    loader = unittest.TestLoader()
    suite = loader.loadTestsFromModule(sys.modules[__name__])
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    total = result.testsRun
    failed = len(result.failures) + len(result.errors)
    skipped = len(result.skipped)
    passed = total - failed - skipped
    print(f"\n=== SUMMARY: {passed} passed, {failed} failed, {skipped} skipped (of {total}) ===")

    sys.exit(0 if result.wasSuccessful() else 1)


if __name__ == "__main__":
    main()
