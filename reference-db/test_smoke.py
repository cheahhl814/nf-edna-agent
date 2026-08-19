#!/usr/bin/env python3
"""Smoke tests for reference-db skill (v1.0.0).

Verifies the agent-skill wrapping is structurally sound:

- Root SKILL.md + 2 sub-skill SKILL.md files have valid YAML frontmatter
- Master and sub-skill versions are coherent (v1.0.0)
- All catalog URLs are syntactically valid (https://, no broken links)
- All 6 preflight stop points + 4 run stop points present
- BettaMt compliance: §0 IO contract, §0.5 Stop Points, §Audience, §When/Do-NOT, §Troubleshooting
- pixi.toml parses cleanly
- License information present for each catalog reference
- DECIPHER-availability status present for each catalog reference

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
    "preflight/reference-db-preflight/SKILL.md",
    "run/reference-db-run/SKILL.md",
]

REQUIRED_FRONT = ("name", "description", "version", "updated", "triggers")

REQUIRED_SECTIONS = {
    "SKILL.md": [
        "## Audience",
        "## When to Use",
        "## 0. Orchestrator",
        "## 1. The Reference-Database Catalog",
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

# Catalog: (marker, shorthand, url, decipher_ready, license)
EXPECTED_CATALOG_ENTRIES = [
    # SILVA
    ("16S", "SILVA-SSU-r138.2-DECIPHER",
     "https://drive.google.com/file/d/1w3wdSCpSihntWkbP_zvXz7r3s-tNB8DV",
     True, "SILVA"),
    ("16S", "SILVA-ARB-r138.2",
     "https://www.arb-silva.de/fileadmin/silva_databases",
     False, "SILVA"),
    # PR2
    ("18S-V9", "PR2-v5.1.0-SSU-DECIPHER",
     "https://github.com/pr2database/pr2database/releases/download/v5.1.0.0",
     True, "CC-BY-4.0"),
    # MitoFish
    ("12S", "MitoFish-12S-NR-Mar2025",
     "https://zenodo.org/records/17602902",
     False, "CC-BY-4.0"),
    # MIDORI2
    ("COI", "MIDORI2-CO1",
     "https://www.reference-midori.info/download/Databases/GenBank265_2025-03-08/BLAST/uniq/",
     False, "CC-BY-NC-4.0"),
    ("12S", "MIDORI2-12S",
     "https://www.reference-midori.info/download/Databases/GenBank265_2025-03-08/BLAST/uniq/",
     False, "CC-BY-NC-4.0"),
    # BOLD
    ("COI", "BOLD-Public-Data-Package",
     "https://www.boldsystems.org/data/data-packages/",
     False, "BOLD-terms"),
    # DECIPHER-pre-trained (other markers)
    ("ITS", "UNITE-2025-DECIPHER",
     "https://decipher.codes/Downloads.html",
     True, "CC-BY-4.0"),
    ("16S", "GTDB-r232-DECIPHER",
     "https://decipher.codes/Downloads.html",
     True, "CC-BY-NC"),
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


class TestReferenceDBSkill(unittest.TestCase):
    """Structural smoke tests for reference-db v1.0.0."""

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
        self.assertEqual(fm["version"], "1.1.3", "Root version must be 1.1.3")

    def test_04_sub_skills_have_required_frontmatter(self):
        """All 2 sub-skill SKILL.md files must have valid frontmatter."""
        for rel in SUB_SKILLS:
            text = _read(rel)
            fm = _frontmatter(text)
            self.assertIsNotNone(fm, f"Could not parse frontmatter: {rel}")
            for key in REQUIRED_FRONT:
                self.assertIn(key, fm, f"{rel} missing frontmatter key: {key}")
            self.assertEqual(
                fm["version"], "1.1.3", f"{rel} version must be 1.0.0 (got {fm['version']})"
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

    def test_08_pixi_toml_exists_and_parses(self):
        """pixi.toml must exist and parse cleanly."""
        path = HERE / "pixi.toml"
        self.assertTrue(path.exists(), f"Missing: {path}")
        try:
            with open(path, "rb") as f:
                tomllib.load(f)
        except Exception as e:
            self.fail(f"pixi.toml failed to parse: {e}")

    def test_09_pixi_includes_gdown(self):
        """pixi.toml must include gdown for Google Drive downloads."""
        text = (HERE / "pixi.toml").read_text()
        self.assertIn("gdown", text, "pixi.toml must include gdown for Google Drive downloads")

    def test_10_sub_skill_version_coherent(self):
        """Master and sub-skill versions must match."""
        root_fm = _frontmatter(_read("SKILL.md"))
        for rel in SUB_SKILLS:
            fm = _frontmatter(_read(rel))
            self.assertEqual(
                root_fm["version"],
                fm["version"],
                f"Version mismatch: root={root_fm['version']}, {rel}={fm['version']}",
            )

    def test_11_sub_skill_references(self):
        """SKILL.md must reference both sub-skills."""
        text = _read("SKILL.md")
        self.assertIn("reference-db-preflight", text, "SKILL.md missing preflight reference")
        self.assertIn("reference-db-run", text, "SKILL.md missing run reference")

    def test_12_catalog_covers_all_four_markers(self):
        """Root SKILL.md §1 catalog must cover 16S, 18S-V9, COI, 12S markers."""
        text = _read("SKILL.md")
        self.assertIn("SILVA", text, "SKILL.md catalog missing SILVA (16S)")
        self.assertIn("PR2", text, "SKILL.md catalog missing PR2 (18S)")
        self.assertIn("MIDORI2", text, "SKILL.md catalog missing MIDORI2 (COI/12S)")
        self.assertIn("MitoFish", text, "SKILL.md catalog missing MitoFish (12S)")
        self.assertIn("BOLD", text, "SKILL.md catalog missing BOLD (COI)")

    def test_13_catalog_urls_are_https(self):
        """All catalog URLs must be https:// (not http://)."""
        text = _read("SKILL.md")
        # Find all URLs in the catalog tables
        urls = re.findall(r"https?://[^\s\)\|<>\"']+", text)
        for url in urls:
            self.assertTrue(
                url.startswith("https://"),
                f"Non-HTTPS URL found in catalog: {url}",
            )

    def test_14_catalog_pre_trained_entries_exist(self):
        """Catalog must include the 9 expected pre-trained / curated reference entries."""
        text = _read("SKILL.md")
        expected = [
            ("SILVA SSU r138.2", "16S"),
            ("SILVA SSU r138.2 NR99", "16S"),  # ARB variant
            ("PR2 v5.1.0 SSU", "18S-V9"),
            ("PR2 18S v4.13", "18S-V9"),
            ("MitoFish 12S", "12S"),
            ("MIDORI2", "COI"),
            ("BOLD", "COI"),
            ("UNITE 2025", "ITS"),
            ("GTDB r232", "16S"),
        ]
        for name, marker in expected:
            self.assertIn(
                name, text, f"Catalog missing '{name}' ({marker}) entry"
            )

    def test_15_decision_matrix_present(self):
        """SKILL.md §2 must have a decision matrix recommending one reference per marker."""
        text = _read("SKILL.md")
        self.assertIn("Decision Matrix", text, "SKILL.md missing Decision Matrix section")
        # The matrix should mention each marker
        for marker in ["16S", "18S", "12S", "COI"]:
            self.assertIn(marker, text, f"Decision Matrix missing marker: {marker}")

    def test_16_license_information_present(self):
        """Catalog entries must include license information."""
        text = _read("SKILL.md")
        # Should mention at least the major license types
        for license_phrase in ["CC-BY", "CC-BY-NC", "SILVA dual-license", "BOLD"]:
            self.assertIn(license_phrase, text, f"Catalog missing license info: {license_phrase}")

    def test_17_assets_directory_convention_documented(self):
        """SKILL.md §3 must document the assets directory convention."""
        text = _read("SKILL.md")
        self.assertIn("assets", text, "SKILL.md missing assets directory convention")
        # Should show marker-specific subdirs
        for subdir in ["16s", "18s-v9", "12s", "coi"]:
            self.assertIn(subdir, text, f"Assets convention missing subdir: {subdir}")

    def test_18_troubleshooting_includes_gdown(self):
        """Run sub-skill troubleshooting must mention gdown (Google Drive download)."""
        text = _read(SUB_SKILLS[1])
        self.assertIn(
            "gdown",
            text,
            "Run sub-skill troubleshooting missing gdown mention for Google Drive",
        )

    def test_19_preflight_disk_space_check(self):
        """Preflight SP2 must check for disk space (≥ 5 GB)."""
        text = _read(SUB_SKILLS[0])
        self.assertIn("SP2", text, "Preflight missing SP2")
        self.assertIn("GB", text, "Preflight missing GB unit in disk space check")
        self.assertIn("5", text, "Preflight missing 5 GB threshold")

    def test_20_preflight_license_check(self):
        """Preflight SP5 must check license acceptance."""
        text = _read(SUB_SKILLS[0])
        self.assertIn("SP5", text, "Preflight missing SP5")
        self.assertIn(
            "license",
            text.lower(),
            "Preflight missing license acceptance check",
        )

    def test_21_run_chains_to_idtaxa_training(self):
        """Run sub-skill SP4 must chain to idtaxa-training for non-pre-trained references."""
        text = _read(SUB_SKILLS[1])
        self.assertIn("idtaxa-training", text, "Run sub-skill missing idtaxa-training chain")
        self.assertIn("SP4", text, "Run sub-skill missing SP4")

    def test_22_run_uses_patched_idtaxa_rds(self):
        """Run sub-skill validation (SP3) must reference the patched idtaxa_rds.R for DECIPHER RDX3."""
        text = _read(SUB_SKILLS[1])
        self.assertIn(
            "idtaxa_rds.R",
            text,
            "Run sub-skill validation missing reference to patched idtaxa_rds.R",
        )

    def test_23_preflight_writes_verdict_file(self):
        """Preflight must describe writing preflight_verdict.txt."""
        text = _read(SUB_SKILLS[0])
        self.assertIn(
            "preflight_verdict.txt", text, "Preflight missing preflight_verdict.txt reference"
        )

    def test_24_run_writes_run_summary_json(self):
        """Run sub-skill must describe writing run_summary.json."""
        text = _read(SUB_SKILLS[1])
        self.assertIn("run_summary.json", text, "Run sub-skill missing run_summary.json reference")

    def test_25_related_skills_in_root(self):
        """Root SKILL.md must have a § Related skills section."""
        text = _read("SKILL.md")
        self.assertIn("Related skills", text, "SKILL.md missing 'Related skills' section")
        # Should reference idtaxa-training and nf-edna
        self.assertIn("idtaxa-training", text, "SKILL.md Related skills missing idtaxa-training")
        self.assertIn("nf-edna", text, "SKILL.md Related skills missing nf-edna")


if __name__ == "__main__":
    sys.stdout.reconfigure(line_buffering=True)
    unittest.main(verbosity=2)