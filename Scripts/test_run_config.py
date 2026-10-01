"""Check that T3 worktrees inherit ignored maintainer runner settings."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

script = Path(__file__).with_name("run.sh")
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    main, worktree, tools = root / "main", root / "worktree", root / "tools"
    (main / "Scripts").mkdir(parents=True)
    (tools / "macos").mkdir(parents=True)
    shutil.copy2(script, main / "Scripts/run.sh")
    (main / ".gitignore").write_text("Scripts/run.local.config\n")
    runner = tools / "macos/run.sh"
    runner.write_text('#!/bin/bash\nprintf "%s|%s" "$TEAM_ID" "$SEND_TARGET"\n')
    runner.chmod(0o755)
    def git(*args):
        subprocess.run(["git", "-C", str(main), *args], check=True, capture_output=True)
    git("init")
    git("add", ".")
    git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture")
    (main / "Scripts/run.local.config").write_text(
        f"BUILD_TOOLS={tools}\nTEAM_ID=fixture-team\nSEND_TARGET=fixture-host\n")
    git("worktree", "add", "--detach", str(worktree))
    for checkout in [main, worktree]:
        result = subprocess.check_output(["bash", str(checkout / "Scripts/run.sh"), "local", "fast"], text=True)
        assert result == "fixture-team|fixture-host", result
print("PASS: main checkout and T3 worktree use ignored local runner settings")
