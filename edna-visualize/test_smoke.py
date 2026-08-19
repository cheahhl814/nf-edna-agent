#!/usr/bin/env python3
"""Smoke tests for eDNA-visualize skill (v1.0.0).

Verifies the agent-skill wrapping is structurally sound:

- Root SKILL.md + 2 sub-skill SKILL.md files have valid YAML frontmatter
  (name, description, version, updated, triggers, requires)
- Master and sub-skill versions are coherent (v1.0.0)
- Sub-skill contract wiring (preflight → run via pipeline_state.json + verdict)
- All 3 bin/ scripts parse cleanly (R)
- pixi.toml parses cleanly
- Signature library exists in root + run sub-skill
- BettaMt compliance: §0 IO contract, §0.5 Stop Points, §Audience, §When/Do-NOT, §Troubleshooting

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
    "preflight/edna-visualize-preflight/SKILL.md",
    "run/edna-visualize-run/SKILL.md",
]

REQUIRED_FRONT = ("name", "description", "version", "updated", "triggers")

REQUIRED_SECTIONS = {
    "SKILL.md": [
        "## Audience",
        "## When to Use This Skill",
        "## 0. Orchestrator",
        "## 1. Inputs",
        "## 2. Outputs",
        "Troubleshooting",
        "## Verification",
        "## Invariants",
    ],
    "preflight": [
        "## Audience",
        "## When to Use",
        "## 0. Inputs / Outputs",
        "## 0.5 Ask-User Stop Points",
        "## 1. Verdict Gate",
        "Troubleshooting",
        "## Verification",
        "## Invariants",
    ],
    "run": [
        "## Audience",
        "## When to Use",
        "## 0. Inputs / Outputs",
        "## 0.5 Ask-User Stop Points",
        "## 1. Run State",
        "Troubleshooting",
        "## Verification",
        "## Invariants",
    ],
}

BIN_SCRIPTS = [
    "bin/normalize_abundance.R",
    "bin/plot_heatmaps.R",
    "bin/plot_stacked_bar.R",
]


def _read(rel):
    return (HERE / rel).read_text()


def _frontmatter(text):
    """Return the YAML frontmatter dict from a SKILL.md file."""
    parts = text.split("---", 2)
    if len(parts) < 3:
        return None
    try:
        import yaml

        return yaml.safe_load(parts[1])
    except ImportError:
        m = re.search(r"^name:\s*(\S+)", parts[1], re.M)
        return {"name": m.group(1) if m else None}


def _has_required_sections(text, required):
    """Return (missing_list, ok_bool)."""
    missing = [s for s in required if s not in text]
    return missing, len(missing) == 0


class TestEDNAVisualizeSkill(unittest.TestCase):
    """Structural smoke tests for eDNA-visualize v1.0.0."""

    def test_01_root_skill_md_exists(self):
        """Root SKILL.md must exist."""
        path = HERE / "SKILL.md"
        self.assertTrue(path.exists(), f"Missing: {path}")

    def test_02_sub_skill_md_files_exist(self):
        """All 2 sub-skill SKILL.md files must exist."""
        for rel in SUB_SKILLS:
            path = HERE / rel
            self.assertTrue(path.exists(), f"Missing sub-skill: {path}")

    def test_03_root_skill_md_has_required_frontmatter(self):
        """Root SKILL.md must have all required frontmatter keys."""
        text = _read("SKILL.md")
        fm = _frontmatter(text)
        self.assertIsNotNone(fm, "Could not parse frontmatter")
        for key in REQUIRED_FRONT:
            self.assertIn(key, fm, f"Root SKILL.md missing frontmatter key: {key}")
        self.assertEqual(fm["version"], "1.1.4", "Root version must be 1.1.4")

    def test_04_sub_skills_have_required_frontmatter(self):
        """All 2 sub-skill SKILL.md files must have valid frontmatter."""
        for rel in SUB_SKILLS:
            text = _read(rel)
            fm = _frontmatter(text)
            self.assertIsNotNone(fm, f"Could not parse frontmatter: {rel}")
            for key in REQUIRED_FRONT:
                self.assertIn(key, fm, f"{rel} missing frontmatter key: {key}")
            self.assertEqual(
                fm["version"], "1.1.4", f"{rel} version must be 1.0.0 (got {fm['version']})"
            )

    def test_05_sub_skills_have_required_sections(self):
        """All SKILL.md files must have the BettaMt-canonical sections."""
        text = _read("SKILL.md")
        missing, ok = _has_required_sections(text, REQUIRED_SECTIONS["SKILL.md"])
        self.assertTrue(ok, f"SKILL.md missing sections: {missing}")

        text = _read(SUB_SKILLS[0])
        missing, ok = _has_required_sections(text, REQUIRED_SECTIONS["preflight"])
        self.assertTrue(ok, f"Preflight SKILL.md missing sections: {missing}")

        text = _read(SUB_SKILLS[1])
        missing, ok = _has_required_sections(text, REQUIRED_SECTIONS["run"])
        self.assertTrue(ok, f"Run SKILL.md missing sections: {missing}")

    def test_06_stop_points_use_evidence_recommend_options(self):
        """All SPx stop points must follow Evidence + Recommend + Options pattern."""
        for rel in SUB_SKILLS:
            text = _read(rel)
            self.assertIn(
                "**Evidence**:",
                text,
                f"{rel} missing **Evidence**: pattern in stop points",
            )
            self.assertIn(
                "**Recommend**:",
                text,
                f"{rel} missing **Recommend**: pattern in stop points",
            )
            self.assertIn(
                "Options:",
                text,
                f"{rel} missing Options: pattern in stop points",
            )

    def test_07_signature_library_present(self):
        """Root and run sub-skill must have Troubleshooting — Signature library."""
        for rel in ["SKILL.md", SUB_SKILLS[1]]:
            text = _read(rel)
            self.assertIn("Troubleshooting", text, f"{rel} missing 'Troubleshooting' section")
            self.assertIn("Signature library", text, f"{rel} missing 'Signature library' table")

    def test_08_bin_scripts_exist(self):
        """All 3 bin/ scripts must exist."""
        for rel in BIN_SCRIPTS:
            path = HERE / rel
            self.assertTrue(path.exists(), f"Missing bin script: {path}")

    def test_09_bin_r_scripts_parse(self):
        """R scripts must parse as valid R (no syntax errors)."""
        import subprocess

        for rel in BIN_SCRIPTS:
            result = subprocess.run(
                ["Rscript", "-e", f"parse(file='{HERE / rel}'); cat('OK')"],
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(
                result.returncode, 0, f"R script failed to parse: {rel}\n{result.stderr}"
            )
            self.assertIn("OK", result.stdout, f"R script no OK: {rel}")

    def test_10_pixi_toml_exists_and_parses(self):
        """pixi.toml must exist and parse cleanly."""
        path = HERE / "pixi.toml"
        self.assertTrue(path.exists(), f"Missing: {path}")
        try:
            with open(path, "rb") as f:
                tomllib.load(f)
        except Exception as e:
            self.fail(f"pixi.toml failed to parse: {e}")

    def test_11_sub_skill_version_coherent(self):
        """Master and sub-skill versions must match."""
        root_fm = _frontmatter(_read("SKILL.md"))
        for rel in SUB_SKILLS:
            fm = _frontmatter(_read(rel))
            self.assertEqual(
                root_fm["version"],
                fm["version"],
                f"Version mismatch: root={root_fm['version']}, {rel}={fm['version']}",
            )

    def test_12_sub_skill_references(self):
        """SKILL.md must reference both sub-skills."""
        text = _read("SKILL.md")
        self.assertIn("edna-visualize-preflight", text, "SKILL.md missing preflight reference")
        self.assertIn("edna-visualize-run", text, "SKILL.md missing run reference")

    def test_13_triggers_use_visualization_terminology(self):
        """Root SKILL.md triggers must include visualization terminology."""
        fm = _frontmatter(_read("SKILL.md"))
        triggers = fm.get("triggers", [])
        triggers_text = " ".join(triggers)
        self.assertTrue(
            any(kw in triggers_text for kw in ["heatmap", "stacked", "figure", "visualiz"]),
            "Triggers must include visualization terminology (heatmap, stacked, figure, visualiz)",
        )

    def test_14_run_state_writes_pipeline_state_json(self):
        """Run sub-skill must describe writing pipeline_state.json."""
        text = _read(SUB_SKILLS[1])
        self.assertIn("pipeline_state.json", text, "Run sub-skill missing pipeline_state.json reference")

    def test_15_run_state_writes_run_summary_json(self):
        """Run sub-skill must describe writing run_summary.json."""
        text = _read(SUB_SKILLS[1])
        self.assertIn("run_summary.json", text, "Run sub-skill missing run_summary.json reference")

    def test_16_preflight_writes_verdict_file(self):
        """Preflight must describe writing preflight_verdict.txt."""
        text = _read(SUB_SKILLS[0])
        self.assertIn(
            "preflight_verdict.txt", text, "Preflight missing preflight_verdict.txt reference"
        )

    def test_17_outputs_includes_heatmaps_and_stacked_bars(self):
        """Root SKILL.md §2 Outputs must list heatmaps and stacked bars."""
        text = _read("SKILL.md")
        self.assertIn("heatmap_", text, "SKILL.md missing heatmap output references")
        self.assertIn("stacked_bar", text, "SKILL.md missing stacked_bar output references")

    def test_18_preflight_validates_sample_id_consistency(self):
        """Preflight must validate sample-ID consistency across inputs (SP2)."""
        text = _read(SUB_SKILLS[0])
        self.assertIn("SP2", text, "Preflight missing SP2")
        self.assertIn(
            "consistent", text.lower(),
            "Preflight missing sample-ID consistency check",
        )

    def test_19_run_uses_mia_or_miaviz(self):
        """Run sub-skill must reference mia/miaViz for plotting."""
        text = _read(SUB_SKILLS[1])
        # Run sub-skill describes the commands; mia/miaViz are in bin scripts.
        # But the run sub-skill's signature library should reference them.
        self.assertTrue(
            "mia" in text.lower() or "sechm" in text.lower() or "ComplexHeatmap" in text,
            "Run sub-skill must reference mia/sechm/ComplexHeatmap in signature library",
        )

    def test_20_related_skills_section_in_root(self):
        """Root SKILL.md must have a § Related skills section."""
        text = _read("SKILL.md")
        self.assertIn("Related skills", text, "SKILL.md missing 'Related skills' section")
        # Should reference nf-edna
        self.assertIn("nf-edna", text, "SKILL.md missing nf-edna reference in Related skills")


if __name__ == "__main__":
    sys.stdout.reconfigure(line_buffering=True)
    unittest.main(verbosity=2)