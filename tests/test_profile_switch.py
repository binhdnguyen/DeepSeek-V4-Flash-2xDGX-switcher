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


def run_helper(repo: Path, command: str, *args: str) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment.update(
        {
            "SCRIPT_DIR": str(repo),
            "PROFILE_DIR": str(repo / "profiles"),
            "PROFILE_STATE_FILE": str(repo / ".profile-state"),
        }
    )
    return subprocess.run(
        [
            "bash",
            "-c",
            'set -euo pipefail; source "$SCRIPT_DIR/scripts/profile_switch_lib.sh"; "$@"',
            "profile-switch-helper",
            command,
            *args,
        ],
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


def test_profile_env_prefers_local_override(switch_repo: Path):
    local_env = switch_repo / "profiles" / "robolab" / ".env.local"
    local_env.write_text("PROFILE_NAME=robolab\nDSPARK_MODEL=local-model\n")

    result = run_helper(switch_repo, "profile_env", "robolab")

    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == str(local_env)


@pytest.mark.parametrize(
    ("line", "expected"),
    [
        ("MODEL=unquoted-value", "unquoted-value"),
        ('MODEL="double quoted value"', "double quoted value"),
    ],
)
def test_profile_value_reads_supported_env_values(
    switch_repo: Path, line: str, expected: str
):
    profile_env = switch_repo / "profiles" / "0731" / "profile.env"
    profile_env.write_text(f"PROFILE_NAME=0731\n{line}\n")

    result = run_helper(switch_repo, "profile_value", "0731", "MODEL")

    assert result.returncode == 0, result.stderr
    assert result.stdout == expected


def test_validate_profile_layout_rejects_profile_name_mismatch(switch_repo: Path):
    profile_env = switch_repo / "profiles" / "robolab" / "profile.env"
    profile_env.write_text("PROFILE_NAME=dspark\n")

    result = run_helper(switch_repo, "validate_profile_layout", "robolab")

    assert result.returncode == 1
    assert "PROFILE_NAME mismatch for robolab" in result.stderr


@pytest.mark.parametrize("adapter", ["start", "stop", "verify"])
def test_validate_profile_layout_rejects_non_executable_adapter(
    switch_repo: Path, adapter: str
):
    adapter_path = switch_repo / "profiles" / "robolab" / f"{adapter}.sh"
    adapter_path.chmod(adapter_path.stat().st_mode & ~stat.S_IXUSR)

    result = run_helper(switch_repo, "validate_profile_layout", "robolab")

    assert result.returncode == 1
    assert f"missing executable adapter: {adapter_path}" in result.stderr


def test_write_active_profile_atomically_replaces_state(switch_repo: Path):
    state_file = switch_repo / ".profile-state"
    state_file.write_text("0731\n")

    result = run_helper(switch_repo, "write_active_profile", "robolab")

    assert result.returncode == 0, result.stderr
    assert state_file.read_text() == "robolab\n"
    assert list(switch_repo.glob(".profile-state.tmp.*")) == []
