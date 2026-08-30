#!/usr/bin/env python3
"""nf-edna skill update check (v1.1.4).

Compares the deployed skill's git SHA + version to the upstream repo
(github.com/cheahhl814/nf-edna). No network calls beyond `git fetch`.

Verdicts:
  UP-TO-DATE       local HEAD matches origin/HEAD (or origin/<default-branch>)
  LOCAL-AHEAD      local has unpushed commits (HEAD ahead of origin/HEAD)
  BEHIND-BY-N      upstream is N commits ahead of local
  OFFLINE          git fetch failed (no network / no credentials)
  NO-ORIGIN        this checkout has no `origin` remote
  NO-GIT           this skill is not inside a git checkout

Exit codes:
  0  UP-TO-DATE or LOCAL-AHEAD (no action needed)
  1  BEHIND-BY-N (re-run deploy sync per AGENTS.md §4a)
  2  OFFLINE / NO-ORIGIN / NO-GIT (informational; not an error)

Usage: pixi run update-check
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

# ponytail: stdlib only. Single file. Compares git SHAs; no GitHub API call.


def find_skill_root(start: Path) -> Path | None:
    """Walk up from `start` until we find a directory containing SKILL.md and .git/.
    Also tries Path.cwd() — the user typically runs `pixi run update-check` from
    the skill root, so cwd may be a faster path than the script location (which
    could live anywhere if the script was symlinked or vendored)."""
    for start_path in {start, Path.cwd()}:
        cur = start_path.resolve()
        for p in [cur, *cur.parents]:
            if (p / "SKILL.md").is_file() and (p / ".git").exists():
                return p
            if p == p.parent:
                break
    return None


def git(*args: str, cwd: Path) -> tuple[int, str, str]:
    proc = subprocess.run(
        ["git", *args],
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=30,
    )
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()


def parse_version(skill_md: Path) -> str | None:
    text = skill_md.read_text(encoding="utf-8", errors="replace")
    m = re.search(r"^version:\s*['\"]?([^'\"\n]+)['\"]?", text, re.MULTILINE)
    return m.group(1).strip() if m else None


def upstream_skill_md(skill_root: Path, origin_ref: str) -> Path | None:
    """The fetched upstream's SKILL.md (e.g. fetched via `git fetch`). Lives in .git, not on disk normally.

    Tries the symbolic origin/HEAD first; falls back to the resolved branch
    (origin/master or origin/main) when origin/HEAD isn't configured. Many
    `gh clone` and shallow checkouts leave origin/HEAD unset.
    """
    for ref in ("origin/HEAD", origin_ref):
        rc, out, _ = git("show", f"{ref}:SKILL.md", cwd=skill_root)
        if rc == 0 and out:
            tmp = skill_root / ".git" / "update-check-upstream-SKILL.md"
            tmp.write_text(out, encoding="utf-8")
            return tmp
    return None


def main() -> int:
    here = Path(__file__).resolve().parent
    skill_root = find_skill_root(here)
    if skill_root is None:
        print("NO-GIT: not inside a git checkout (no .git/ next to SKILL.md)")
        return 2

    rc, local_sha, _ = git("rev-parse", "HEAD", cwd=skill_root)
    if rc != 0 or not local_sha:
        print("NO-GIT: git rev-parse HEAD failed")
        return 2

    rc, remote_url, _ = git("remote", "get-url", "origin", cwd=skill_root)
    if rc != 0 or not remote_url:
        print("NO-ORIGIN: no `origin` remote configured")
        print(f"  skill_root: {skill_root}")
        print(f"  local_sha:  {local_sha[:12]}")
        return 2

    # Best-effort fetch. Offline / auth failure → OFFLINE.
    rc, _, err = git("fetch", "--quiet", "origin", cwd=skill_root)
    if rc != 0:
        print(f"OFFLINE: git fetch origin failed ({err.splitlines()[0] if err else 'unknown'})")
        print(f"  remote:    {remote_url}")
        print(f"  local_sha: {local_sha[:12]}")
        print(f"  deployed:  v{parse_version(skill_root / 'SKILL.md') or '?'}")
        return 2

    # Resolve origin/HEAD (falls back to origin/master for repos without symbolic HEAD).
    rc, origin_ref, _ = git("symbolic-ref", "refs/remotes/origin/HEAD", cwd=skill_root)
    if rc != 0 or not origin_ref:
        origin_ref = "refs/remotes/origin/master"
    rc, upstream_sha, _ = git("rev-parse", "--verify", origin_ref, cwd=skill_root)
    if rc != 0 or not upstream_sha:
        origin_ref = "refs/remotes/origin/main"
        rc, upstream_sha, _ = git("rev-parse", "--verify", origin_ref, cwd=skill_root)
    if not upstream_sha:
        print("OFFLINE: could not resolve origin/HEAD, origin/master, or origin/main")
        return 2

    # Commit-count delta (ahead / behind).
    _, ahead, _ = git("rev-list", "--count", f"{upstream_sha}..{local_sha}", cwd=skill_root)
    _, behind, _ = git("rev-list", "--count", f"{local_sha}..{upstream_sha}", cwd=skill_root)
    ahead_n = int(ahead or 0)
    behind_n = int(behind or 0)

    local_version = parse_version(skill_root / "SKILL.md")
    upstream_md = upstream_skill_md(skill_root, origin_ref)
    upstream_version = parse_version(upstream_md) if upstream_md else None
    if upstream_md:
        upstream_md.unlink(missing_ok=True)

    print(f"remote:           {remote_url}")
    print(f"local_sha:        {local_sha[:12]} (v{local_version or '?'})")
    print(f"upstream_sha:     {upstream_sha[:12]} (v{upstream_version or '?'})")
    print(f"ahead/behind:     {ahead_n} / {behind_n}")

    if local_sha == upstream_sha:
        print("verdict:          UP-TO-DATE")
        return 0
    if ahead_n > 0 and behind_n == 0:
        print("verdict:          LOCAL-AHEAD (unpushed commits on local branch)")
        return 0
    if behind_n > 0:
        print(f"verdict:          BEHIND-BY-{behind_n}")
        # ponytail: print both the source-of-truth sync (AGENTS.md §4a) and the
        # git pull alternative. Skill authors may not have a remote-authenticated
        # checkout, so the rsync-via-source-of-truth is the canonical fix.
        print("fix:")
        print("  Option A (canonical, no git auth needed):")
        print("    1. rsync -a --exclude='.git' \\")
        print("         ~/claude_workspace/bioinformatics/AIx-BIO/skills/nf-edna/ \\")
        print("         ~/.pi/agent/skills/nf-edna/")
        print("    2. diff -rq <src> <dst> --exclude='.git'   # verify zero drift")
        print("  Option B (if you have a git checkout of this skill):")
        print(f"    git pull --ff-only origin $(basename {origin_ref.replace('refs/remotes/origin/', '')})")
        return 1
    print(f"verdict:          DIVERGED (ahead={ahead_n}, behind={behind_n}) — manual reconcile")
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except subprocess.TimeoutExpired:
        print("OFFLINE: git fetch timed out")
        sys.exit(2)