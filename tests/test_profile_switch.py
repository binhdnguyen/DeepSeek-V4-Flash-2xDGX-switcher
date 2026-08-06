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
            adapter.write_text(
                "#!/usr/bin/env bash\n"
                "set -euo pipefail\n"
                f"printf '%s\\n' '{profile} {action}' >> \"${{LIFECYCLE_LOG}}\"\n"
                f"exit \"${{EXIT_{profile.upper()}_{action.upper()}:-0}}\"\n"
            )
            adapter.chmod(adapter.stat().st_mode | stat.S_IXUSR)

    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    curl = fake_bin / "curl"
    curl.write_text(
        "#!/usr/bin/env bash\n"
        "case \"${*: -1}\" in\n"
        "  */metrics) printf '%s\\n' \"${FAKE_METRICS:-}\" ;;\n"
        "  */v1/models) printf '%s\\n' \"${FAKE_MODELS:-{\\\"data\\\":[]}}\" ;;\n"
        "esac\n"
    )
    curl.chmod(curl.stat().st_mode | stat.S_IXUSR)
    for command in ("jq", "ss", "docker", "ssh"):
        executable = fake_bin / command
        executable.write_text("#!/usr/bin/env bash\nexit 0\n")
        executable.chmod(executable.stat().st_mode | stat.S_IXUSR)

    return tmp_path


def run_switch(
    repo: Path, *args: str, extra_env: dict[str, str] | None = None
) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment.update(
        {
            "SWITCH_REPO_ROOT": str(repo),
            "PROFILE_STATE_FILE": str(repo / ".profile-state"),
            "API_URL": "http://127.0.0.1:1/v1/models",
            "METRICS_URL": "http://127.0.0.1:1/metrics",
            "LIFECYCLE_LOG": str(repo / "lifecycle.log"),
            "PATH": f"{repo / 'fake-bin'}:{environment['PATH']}",
        }
    )
    environment.update(extra_env or {})
    return subprocess.run(
        [str(repo / "switch-deepseek-v4-flash.sh"), *args],
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


def test_profiles_expose_distinct_served_model_names():
    expected = {
        "dspark": "deepseek-v4-flash-dspark",
        "0731": "deepseek-v4-flash-0731",
        "robolab": "deepseek-v4-flash-robolab",
    }
    for profile, model in expected.items():
        env_path = REPO_ROOT / "profiles" / profile / ".env"
        values = dict(
            line.split("=", 1)
            for line in env_path.read_text().splitlines()
            if line and not line.startswith("#") and "=" in line
        )
        assert values["SERVED_MODEL_NAME"].strip('"') == model


def test_robolab_preflight_only_skips_api_readiness_wait():
    start_script = (REPO_ROOT / "profiles" / "robolab" / "start.sh").read_text()
    launcher_call = 'ROBOLAB_CHECKOUT="$ROBOLAB_CHECKOUT" "$patched_launcher"'
    preflight_exit = '[[ "${DSPARK_PREFLIGHT_ONLY:-0}" == "1" ]] && exit 0'
    assert launcher_call in start_script
    assert preflight_exit in start_script
    assert start_script.index(launcher_call) < start_script.index(preflight_exit)
    assert start_script.index(preflight_exit) < start_script.index("for _ in $(seq 1 120)")


def test_robolab_launcher_patch_requires_snapshot_layout():
    start_script = (REPO_ROOT / "profiles" / "robolab" / "start.sh").read_text()
    assert 'path.parent.name != "snapshots"' in start_script
    assert "model path is not an HF snapshot" in start_script


def test_robolab_start_honors_trial_overrides_and_relaxes_k_gate():
    start_script = (REPO_ROOT / "profiles" / "robolab" / "start.sh").read_text()
    assert 'MAX_NUM_SEQS="${MAX_NUM_SEQS:-16}"' in start_script
    assert 'MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-16384}"' in start_script
    assert 'MTP_NUM_TOKENS="${MTP_NUM_TOKENS:-6}"' in start_script
    assert 'KV_CACHE_MEMORY_BYTES="${KV_CACHE_MEMORY_BYTES:-15998753178}"' in start_script
    assert '"${SPEC_TOKENS}" == "5" || "${SPEC_TOKENS}" == "6"' in start_script
    assert 'if [[ "${MTP_NUM_TOKENS}" == "5" ]]; then' in start_script
    assert "admission relaxed for K=5 tuning" in start_script


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

def lifecycle_calls(repo: Path) -> list[str]:
    path = repo / "lifecycle.log"
    return path.read_text().splitlines() if path.exists() else []


def test_dry_run_validates_all_three_profile_adapters(switch_repo: Path):
    result = run_switch(switch_repo, "--dry-run", "robolab")
    assert result.returncode == 0, result.stderr
    assert "DRY-RUN: no changes made" in result.stdout
    assert lifecycle_calls(switch_repo) == []


def test_switch_refuses_when_vllm_has_running_requests(switch_repo: Path):
    write_state(switch_repo, "0731")
    metrics = 'vllm:num_requests_running{engine="0"} 2\nvllm:num_requests_waiting{engine="0"} 0'
    result = run_switch(
        switch_repo, "robolab", extra_env={"FAKE_METRICS": metrics}
    )
    assert result.returncode != 0
    assert "active requests" in result.stderr
    assert lifecycle_calls(switch_repo) == []


def test_switch_refuses_when_live_endpoint_metrics_are_unavailable(switch_repo: Path):
    write_state(switch_repo, "0731")
    result = run_switch(
        switch_repo,
        "robolab",
        extra_env={"FAKE_MODELS": '{"data":[{"id":"deepseek-v4-flash-0731"}]}'},
    )
    assert result.returncode != 0
    assert "metrics unavailable" in result.stderr
    assert lifecycle_calls(switch_repo) == []


def test_switch_refuses_when_live_endpoint_metrics_are_nonnumeric(switch_repo: Path):
    write_state(switch_repo, "0731")
    result = run_switch(
        switch_repo,
        "robolab",
        extra_env={
            "FAKE_MODELS": '{"data":[{"id":"deepseek-v4-flash-0731"}]}',
            "FAKE_METRICS": 'vllm:num_requests_running{engine="0"} NaN\nvllm:num_requests_waiting{engine="0"} 0',
        },
    )
    assert result.returncode != 0
    assert "metrics unavailable" in result.stderr
    assert lifecycle_calls(switch_repo) == []


def test_selecting_recorded_active_profile_revalidates_and_verifies(switch_repo: Path):
    write_state(switch_repo, "0731")
    result = run_switch(switch_repo, "0731")
    assert result.returncode == 0, result.stderr
    assert lifecycle_calls(switch_repo) == ["0731 verify"]
    assert "already active and verified" in result.stdout


def test_selecting_recorded_active_profile_fails_when_live_verify_fails(switch_repo: Path):
    write_state(switch_repo, "0731")
    result = run_switch(
        switch_repo, "0731", extra_env={"EXIT_0731_VERIFY": "1"}
    )
    assert result.returncode != 0
    assert lifecycle_calls(switch_repo) == ["0731 verify"]
    assert (switch_repo / ".profile-state").read_text() == "0731\n"


def test_failed_target_start_rolls_back_without_changing_state(switch_repo: Path):
    write_state(switch_repo, "0731")
    result = run_switch(
        switch_repo,
        "robolab",
        extra_env={
            "EXIT_ROBOLAB_START": "1",
            "FAKE_METRICS": 'vllm:num_requests_running{engine="0"} 0\nvllm:num_requests_waiting{engine="0"} 0',
        },
    )
    assert result.returncode != 0
    assert lifecycle_calls(switch_repo) == [
        "0731 stop",
        "robolab start",
        "robolab stop",
        "0731 start",
        "0731 verify",
    ]
    assert (switch_repo / ".profile-state").read_text() == "0731\n"


def test_state_changes_only_after_verify(switch_repo: Path):
    write_state(switch_repo, "0731")
    result = run_switch(
        switch_repo,
        "robolab",
        extra_env={
            "EXIT_ROBOLAB_VERIFY": "1",
            "FAKE_METRICS": 'vllm:num_requests_running{engine="0"} 0\nvllm:num_requests_waiting{engine="0"} 0',
        },
    )
    assert result.returncode != 0
    assert lifecycle_calls(switch_repo) == [
        "0731 stop",
        "robolab start",
        "robolab verify",
        "robolab stop",
        "0731 start",
        "0731 verify",
    ]
    assert (switch_repo / ".profile-state").read_text() == "0731\n"
