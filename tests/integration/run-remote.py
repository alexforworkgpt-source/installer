#!/usr/bin/env python3

from __future__ import annotations

import argparse
import os
from pathlib import Path
import hashlib
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile

WORKSPACE = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(WORKSPACE))

from lib.env_helper import parse_env


SSH_KEYS = (
    "SERVER_IP",
    "SERVER_SSH_PORT",
    "SERVER_SSH_USER",
    "SERVER_SSH_PASSWORD",
    "SERVER_SSH_KEY_PATH",
    "SERVER_SSH_HOST_FINGERPRINT",
)
TEST_KEYS = (
    "RUN_INSTALLER_INTEGRATION",
    "TEST_PROJECT_ROOT",
    "TEST_HOOK_DOMAIN",
    "TEST_APP_DOMAIN",
    "TEST_BOT_TOKEN",
    "TEST_BOT_USERNAME",
    "TEST_ADMIN_IDS",
    "TEST_REMNAWAVE_API_URL",
    "TEST_REMNAWAVE_API_KEY",
    "TEST_REMNAWAVE_SECRET_KEY",
    "TEST_REMNAWAVE_WEBHOOK_SECRET",
)


class RemoteIntegrationError(RuntimeError):
    pass


def apply_disposable_confirmation(
    config: dict[str, str], *, confirmed: bool
) -> dict[str, str]:
    effective = dict(config)
    if confirmed:
        effective["SERVER_IS_DISPOSABLE"] = "yes"
    return effective


def require_value(config: dict[str, str], key: str) -> str:
    value = config.get(key, "").strip()
    if not value:
        raise RemoteIntegrationError(f"server.env is missing {key}")
    if "\n" in value or "\r" in value or "\0" in value:
        raise RemoteIntegrationError(f"server.env contains unsafe control data in {key}")
    return value


def validate_config(config: dict[str, str]) -> None:
    if config.get("SERVER_IS_DISPOSABLE", "").strip().lower() != "yes":
        raise RemoteIntegrationError(
            'SERVER_IS_DISPOSABLE must be "yes" before destructive integration'
        )
    host = require_value(config, "SERVER_IP")
    if not re.fullmatch(r"[A-Za-z0-9.:-]+", host):
        raise RemoteIntegrationError("SERVER_IP contains unsupported characters")
    port = require_value(config, "SERVER_SSH_PORT")
    if not port.isdigit() or not 1 <= int(port) <= 65535:
        raise RemoteIntegrationError("SERVER_SSH_PORT is invalid")
    user = require_value(config, "SERVER_SSH_USER")
    if user != "root":
        raise RemoteIntegrationError("the current integration runner requires root SSH")
    if not config.get("SERVER_SSH_PASSWORD") and not config.get("SERVER_SSH_KEY_PATH"):
        raise RemoteIntegrationError("configure SSH password or key path")

    installer_dir = require_value(config, "SERVER_INSTALLER_DIR")
    project_root = require_value(config, "TEST_PROJECT_ROOT")
    for key, value in (
        ("SERVER_INSTALLER_DIR", installer_dir),
        ("TEST_PROJECT_ROOT", project_root),
    ):
        if not value.startswith(("/root/", "/opt/", "/srv/")):
            raise RemoteIntegrationError(f"{key} must be under /root, /opt, or /srv")
        if "integration" not in value.lower():
            raise RemoteIntegrationError(f"{key} must contain 'integration'")
    for key in TEST_KEYS:
        require_value(config, key)
    if config["RUN_INSTALLER_INTEGRATION"] != "1":
        raise RemoteIntegrationError("RUN_INSTALLER_INTEGRATION must equal 1")


class RemoteSession:
    def __init__(self, config: dict[str, str], temp_dir: Path) -> None:
        self.config = config
        self.host = config["SERVER_IP"]
        self.port = config["SERVER_SSH_PORT"]
        self.user = config["SERVER_SSH_USER"]
        self.known_hosts = temp_dir / "known_hosts"
        self.askpass = temp_dir / "askpass.sh"
        self.environment = os.environ.copy()
        password = config.get("SERVER_SSH_PASSWORD", "")
        if password:
            self.askpass.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$BEDOLAGA_SSH_PASSWORD"\n',
                encoding="utf-8",
            )
            os.chmod(self.askpass, 0o700)
            self.environment.update(
                {
                    "BEDOLAGA_SSH_PASSWORD": password,
                    "SSH_ASKPASS": str(self.askpass),
                    "SSH_ASKPASS_REQUIRE": "force",
                    "DISPLAY": "bedolaga-integration",
                }
            )

    def prepare_host_key(self) -> None:
        scan = subprocess.run(
            ["ssh-keyscan", "-T", "10", "-p", self.port, self.host],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        ).stdout
        if not scan.strip():
            raise RemoteIntegrationError("ssh-keyscan returned no host keys")
        expected = self.config.get("SERVER_SSH_HOST_FINGERPRINT", "").strip()
        fingerprints = subprocess.run(
            ["ssh-keygen", "-lf", "-"],
            input=scan,
            check=True,
            stdout=subprocess.PIPE,
        ).stdout.decode("utf-8", errors="replace")
        if expected and expected not in fingerprints:
            raise RemoteIntegrationError("SSH host-key fingerprint does not match server.env")
        self.known_hosts.write_bytes(scan)
        os.chmod(self.known_hosts, 0o600)
        safe_fingerprints = re.findall(r"SHA256:[A-Za-z0-9+/]+", fingerprints)
        print("SSH host key verified:", ", ".join(safe_fingerprints))

    def ssh_command(self, remote_command: str) -> list[str]:
        command = [
            "ssh",
            "-p",
            self.port,
            "-o",
            "BatchMode=no",
            "-o",
            "NumberOfPasswordPrompts=1",
            "-o",
            "ConnectTimeout=15",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            f"UserKnownHostsFile={self.known_hosts}",
            "-o",
            "LogLevel=ERROR",
        ]
        key_path = self.config.get("SERVER_SSH_KEY_PATH", "").strip()
        if key_path:
            key = Path(key_path).expanduser().resolve()
            if not key.is_file():
                raise RemoteIntegrationError("SERVER_SSH_KEY_PATH does not exist")
            command.extend(["-i", str(key), "-o", "IdentitiesOnly=yes"])
        command.extend([f"{self.user}@{self.host}", remote_command])
        return command

    def run(
        self,
        remote_command: str,
        *,
        input_data: bytes | None = None,
        capture_output: bool = False,
        timeout: int = 120,
    ) -> subprocess.CompletedProcess[bytes]:
        return subprocess.run(
            self.ssh_command(remote_command),
            input=input_data,
            check=True,
            env=self.environment,
            stdout=subprocess.PIPE if capture_output else None,
            stderr=subprocess.PIPE if capture_output else None,
            timeout=timeout,
        )


def create_source_archive(workspace: Path, destination: Path) -> None:
    excluded_roots = {".git", ".scratch", "state"}
    with tarfile.open(destination, "w:gz") as archive:
        for path in sorted(workspace.rglob("*")):
            relative = path.relative_to(workspace)
            if relative.parts[0] in excluded_roots:
                continue
            if path.name in {"server.env", "env.txt"} or "__pycache__" in relative.parts:
                continue
            if path.suffix == ".pyc":
                continue
            if path.is_symlink():
                raise RemoteIntegrationError(f"refusing to upload symlink: {relative}")
            archive.add(path, arcname=relative.as_posix(), recursive=False)


def remote_environment(config: dict[str, str]) -> bytes:
    lines = [f"{key}={shlex.quote(config[key])}" for key in TEST_KEYS]
    return ("\n".join(lines) + "\n").encode("utf-8")


def compose_project_name(project_root: str) -> str:
    root = Path(project_root)
    slug = re.sub(r"[^a-z0-9_-]+", "-", root.name.lower()).strip("-_")
    slug = (slug or "stack")[:32]
    digest = hashlib.sha256(str(root).encode("utf-8")).hexdigest()[:8]
    return f"bedolaga-{slug}-{digest}"


def run_preflight(session: RemoteSession, config: dict[str, str]) -> None:
    project_root = shlex.quote(config["TEST_PROJECT_ROOT"])
    command = f"""
set -Eeuo pipefail
[[ "$(id -u)" == "0" ]]
. /etc/os-release
[[ "${{ID}}" == "ubuntu" && "${{VERSION_ID}}" == "24.04" ]]
[[ ! -e {project_root} ]]
available_kb="$(df -Pk / | awk 'NR==2 {{print $4}}')"
memory_kb="$(awk '/MemTotal/ {{print $2}}' /proc/meminfo)"
[[ "${{available_kb}}" -ge 3145728 ]]
[[ "${{memory_kb}}" -ge 1500000 ]]
printf 'Ubuntu=%s; free_disk_kb=%s; memory_kb=%s\n' "${{VERSION_ID}}" "${{available_kb}}" "${{memory_kb}}"
"""
    try:
        result = session.run(command, capture_output=True)
    except subprocess.CalledProcessError as error:
        print((error.stdout or b"").decode("utf-8", errors="replace").strip())
        print((error.stderr or b"").decode("utf-8", errors="replace").strip(), file=sys.stderr)
        raise
    print(result.stdout.decode("utf-8", errors="replace").strip())


def show_package_manager_status(
    session: RemoteSession,
    config: dict[str, str],
) -> None:
    project_root = shlex.quote(config["TEST_PROJECT_ROOT"])
    command = f"""
set -Eeuo pipefail
printf '%s\n' 'Package manager processes:'
ps -eo pid,ppid,etimes,comm,args | awk 'NR == 1 || /apt|dpkg|unattended|cloud-init/'
printf 'unattended-upgrades=%s\n' "$(systemctl is-active unattended-upgrades.service 2>/dev/null || true)"
printf 'cloud-init=%s\n' "$(cloud-init status 2>/dev/null || true)"
printf 'free_disk_kb=%s\n' "$(df -Pk / | awk 'NR==2 {{print $4}}')"
[[ -e {project_root} ]] && printf '%s\n' 'test_project_exists=yes' || printf '%s\n' 'test_project_exists=no'
"""
    result = session.run(command, capture_output=True)
    print(result.stdout.decode("utf-8", errors="replace").strip())


def wait_for_package_manager_and_clean(session: RemoteSession) -> None:
    command = """
set -eu
started_at="$(date +%s)"
locks="/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock"
while true; do
  locked=false
  for lock_file in ${locks}; do
    if [ -e "${lock_file}" ] && fuser "${lock_file}" >/dev/null 2>&1; then
      locked=true
      break
    fi
  done
  [ "${locked}" = "true" ] || break
  [ "$(( $(date +%s) - started_at ))" -lt 900 ] || exit 1
  sleep 5
done
apt-get clean
printf 'free_disk_kb=%s\n' "$(df -Pk / | awk 'NR==2 {print $4}')"
"""
    result = session.run(command, capture_output=True, timeout=930)
    print(result.stdout.decode("utf-8", errors="replace").strip())


def clean_disposable_host(session: RemoteSession) -> None:
    command = """
set -Eeuo pipefail
docker system prune --all --force --volumes
apt-get clean
printf 'free_disk_kb=%s\n' "$(df -Pk / | awk 'NR==2 {print $4}')"
"""
    result = session.run(command, capture_output=True, timeout=600)
    print(result.stdout.decode("utf-8", errors="replace").strip())


def run_postflight(
    session: RemoteSession, config: dict[str, str], *, expect_management: bool = False
) -> None:
    project_root = shlex.quote(config["TEST_PROJECT_ROOT"])
    project_name = shlex.quote(compose_project_name(config["TEST_PROJECT_ROOT"]))
    caddy_file = shlex.quote(
        f"/etc/caddy/conf.d/{compose_project_name(config['TEST_PROJECT_ROOT'])}.caddy"
    )
    integration_env = shlex.quote(
        f"{config['SERVER_INSTALLER_DIR']}/.integration.env"
    )
    management_checks = """
printf 'management launcher=%s current=%s log=%s\n' \
  "$(test -x /usr/local/bin/vpn && printf executable || printf missing)" \
  "$(test -x /opt/bedolaga-installer/current/bot-menu.sh && printf executable || printf missing)" \
  "$(test -f /opt/bedolaga-installer/lifecycle-last.log && stat -c '%a' /opt/bedolaga-installer/lifecycle-last.log || printf missing)"
[[ -x /usr/local/bin/vpn ]]
[[ -x /opt/bedolaga-installer/current/bot-menu.sh ]]
[[ "$(stat -c '%a' /opt/bedolaga-installer/lifecycle-last.log)" == "600" ]]
grep -Fxq 'uninstall:stack-removed-management-preserved' /opt/bedolaga-installer/lifecycle-last.log
""" if expect_management else ""
    command = f"""
set -Eeuo pipefail
printf 'cleanup project=%s caddy=%s env=%s containers=%s volumes=%s\n' \
  "$(test -e {project_root} && printf present || printf absent)" \
  "$(test -e {caddy_file} && printf present || printf absent)" \
  "$(test -e {integration_env} && printf present || printf absent)" \
  "$(docker ps -aq --filter label=com.docker.compose.project={project_name} | wc -l)" \
  "$(docker volume ls -q --filter label=com.docker.compose.project={project_name} | wc -l)"
{management_checks}
[[ ! -e {project_root} ]]
[[ ! -e {caddy_file} ]]
[[ ! -e {integration_env} ]]
[[ -z "$(docker ps -aq --filter label=com.docker.compose.project={project_name})" ]]
[[ -z "$(docker volume ls -q --filter label=com.docker.compose.project={project_name})" ]]
systemctl is-active --quiet caddy
printf '%s\n' 'Remote integration cleanup verified.'
"""
    try:
        result = session.run(command, capture_output=True)
    except subprocess.CalledProcessError as error:
        print((error.stdout or b"").decode("utf-8", errors="replace").strip())
        print(
            (error.stderr or b"").decode("utf-8", errors="replace").strip(),
            file=sys.stderr,
        )
        raise
    print(result.stdout.decode("utf-8", errors="replace").strip())


def run_integration(session: RemoteSession, config: dict[str, str], archive: Path) -> None:
    installer_dir = config["SERVER_INSTALLER_DIR"]
    quoted_installer = shlex.quote(installer_dir)
    session.run(
        f"rm -rf {quoted_installer} && mkdir -p {quoted_installer} && chmod 700 {quoted_installer}",
    )
    session.run(
        f"tar -xzf - -C {quoted_installer}",
        input_data=archive.read_bytes(),
        timeout=300,
    )
    environment_path = f"{installer_dir}/.integration.env"
    session.run(
        f"umask 077; cat > {shlex.quote(environment_path)}",
        input_data=remote_environment(config),
    )
    try:
        session.run(
            f"cd {quoted_installer} && set -a && . ./.integration.env && set +a && bash tests/integration/minimal-stack.sh",
            timeout=2400,
        )
    finally:
        session.run(
            f"rm -f {shlex.quote(environment_path)}",
            timeout=30,
        )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "action",
        choices=("preflight", "apt-status", "prepare", "clean", "postflight", "final-postflight", "run"),
    )
    parser.add_argument("--env", default="server.env")
    parser.add_argument(
        "--confirm-disposable-server",
        action="store_true",
        help="confirm that destructive integration is authorized for this server",
    )
    arguments = parser.parse_args(argv)

    config = apply_disposable_confirmation(
        parse_env((WORKSPACE / arguments.env).resolve()),
        confirmed=arguments.confirm_disposable_server,
    )
    validate_config(config)
    if not shutil.which("ssh") or not shutil.which("ssh-keyscan"):
        raise RemoteIntegrationError("OpenSSH client tools are unavailable")

    with tempfile.TemporaryDirectory(prefix="bedolaga-remote-integration-") as temp:
        temp_dir = Path(temp)
        session = RemoteSession(config, temp_dir)
        session.prepare_host_key()
        if arguments.action == "apt-status":
            show_package_manager_status(session, config)
        elif arguments.action == "prepare":
            wait_for_package_manager_and_clean(session)
        elif arguments.action == "clean":
            clean_disposable_host(session)
        elif arguments.action in {"postflight", "final-postflight"}:
            run_postflight(
                session,
                config,
                expect_management=arguments.action == "final-postflight",
            )
        else:
            run_preflight(session, config)
        if arguments.action == "run":
            archive = temp_dir / "installer.tar.gz"
            create_source_archive(WORKSPACE, archive)
            run_integration(session, config, archive)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except subprocess.CalledProcessError as error:
        print(
            f"remote integration command failed with exit code {error.returncode}",
            file=sys.stderr,
        )
        raise SystemExit(1)
    except subprocess.TimeoutExpired:
        print("remote integration command timed out", file=sys.stderr)
        raise SystemExit(1)
    except (RemoteIntegrationError, OSError) as error:
        print(f"remote integration failed: {error}", file=sys.stderr)
        raise SystemExit(1)
