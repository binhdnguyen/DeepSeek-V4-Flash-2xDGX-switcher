import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def switch_repo(tmp_path: Path) -> Path:
    shutil.copy2(REPO_ROOT / "switch-deepseek-v4-flash.sh", tmp_path)
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    library = REPO_ROOT / "scripts" / "profile_switch_lib.sh"
    if library.exists():
        shutil.copy2(library, scripts)

    profiles = tmp_path / "profiles"
    for profile in ("0731", "dspark", "robolab"):
        profile_dir = profiles / profile
        profile_dir.mkdir(parents=True)
        (profile_dir / "profile.env").write_text(
            f"PROFILE_NAME={profile}\n"
            f"DSPARK_MODEL=deepseek-ai/DeepSeek-V4-Flash-0731\n"
        )
        for action in ("start", "stop", "verify"):
            adapter = profile_dir / f"{action}.sh"
            adapter.write_text("#!/usr/bin/env bash\nexit 0\n")
            adapter.chmod(adapter.stat().st_mode | stat.S_IXUSR)

    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    for command in ("curl", "jq", "ss", "docker", "ssh"):
        executable = fake_bin / command
        executable.write_text("#!/usr/bin/env bash\nexit 0\n")
        executable.chmod(executable.stat().st_mode | stat.S_IXUSR)

    return tmp_path


def run_switch(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    command = """
set -euo pipefail
SCRIPT_DIR="$SWITCH_REPO_ROOT"
PROFILE_DIR="$SCRIPT_DIR/profiles"
source "$SCRIPT_DIR/scripts/profile_switch_lib.sh"
case "${1:-toggle}" in
  --profiles) profile_names ;;
  --check) printf 'active profile : %s\\n' "$(active_profile)" ;;
  --dry-run)
    target="${2:-$(next_profile "$(active_profile)")}" 
    printf 'target profile : %s\\n' "$target"
    ;;
  *) printf 'unsupported test command: %s\\n' "$1" >&2; exit 2 ;;
esac
"""
    environment = os.environ.copy()
    environment.update(
        {
            "SWITCH_REPO_ROOT": str(repo),
            "PROFILE_STATE_FILE": str(repo / ".profile-state"),
            "API_URL": "http://127.0.0.1:1/v1/models",
            "PATH": f"{repo / 'fake-bin'}:{environment['PATH']}",
        }
    )
    return subprocess.run(
        ["bash", "-c", command, "profile-switch-test", *args],
        cwd=repo,
        env=environment,
        text=True,
        capture_output=True,
        check=False,
    )


def write_state(repo: Path, profile: str) -> None:
    (repo / ".profile-state").write_text(f"{profile}\n")


def write_active_env(repo: Path, model: str) -> None:
    (repo / ".env.dspark").write_text(f'DSPARK_MODEL="{model}"\n')


def dry_run_target(repo: Path) -> str:
    result = run_switch(repo, "--dry-run")
    assert result.returncode == 0, result.stderr
    for line in result.stdout.splitlines():
        if line.startswith("target profile : "):
            return line.removeprefix("target profile : ")
    raise AssertionError(f"target profile missing from output: {result.stdout!r}")


def test_lists_profiles_in_declared_order(switch_repo: Path):
    result = run_switch(switch_repo, "--profiles")
    assert result.stdout.split() == ["0731", "dspark", "robolab"]


def test_toggle_cycles_through_three_profiles(switch_repo: Path):
    write_state(switch_repo, "0731")
    assert dry_run_target(switch_repo) == "dspark"
    write_state(switch_repo, "dspark")
    assert dry_run_target(switch_repo) == "robolab"
    write_state(switch_repo, "robolab")
    assert dry_run_target(switch_repo) == "0731"


def test_same_checkpoint_profiles_use_state_not_model_name(switch_repo: Path):
    write_active_env(switch_repo, "deepseek-ai/DeepSeek-V4-Flash-0731")
    write_state(switch_repo, "robolab")
    result = run_switch(switch_repo, "--check")
    assert "active profile : robolab" in result.stdout
