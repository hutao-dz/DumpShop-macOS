"""Transfer and run the device credential retriever over USB SSH."""

from __future__ import annotations

import atexit
import os
import re
import secrets
import shlex
import shutil
import socket
import subprocess
import time
from pathlib import Path


class SSHDevice:
    def __init__(self, port: int, udid: str):
        if not 1 <= port <= 65535:
            raise ValueError("SSH port is out of range")
        self.control_path = "/tmp/fp-ssh-" + secrets.token_hex(8)
        self.tunnel = None
        atexit.register(self.close)
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                pass
        except OSError:
            self.tunnel = subprocess.Popen(
                ["iproxy", "-u", udid, f"{port}:22"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            for _ in range(30):
                if self.tunnel.poll() is not None:
                    raise RuntimeError("USB SSH tunnel exited before opening")
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=1):
                        break
                except OSError:
                    time.sleep(0.1)
            else:
                raise RuntimeError("USB SSH tunnel did not open")
        environment = os.environ.copy()
        username = environment.pop("FAIRPLAY_SSH_USER", "root").strip() or "root"
        if username not in {"root", "mobile"}:
            raise ValueError("unsupported SSH user")
        password = environment.pop("FAIRPLAY_SSH_PASSWORD", "")
        use_sudo = environment.pop("FAIRPLAY_SSH_USE_SUDO", "") == "1"
        if use_sudo and not password:
            self.close()
            raise RuntimeError("Dopamine sudo requires the mobile password")
        self.sudo_password = password if use_sudo else ""
        self.command = [
            "ssh",
            "-q",
            "-o",
            "WarnWeakCrypto=no-pq-kex",
            "-o",
            "StrictHostKeyChecking=accept-new",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "ConnectTimeout=8",
        ]
        if not password:
            self.command += ["-o", "BatchMode=yes"]
        self.command += [
            "-o",
            "ControlMaster=auto",
            "-o",
            f"ControlPath={self.control_path}",
            "-o",
            "ControlPersist=120",
        ]
        self.command += ["-p", str(port), f"{username}@127.0.0.1"]
        self.environment = environment
        if password:
            sshpass = shutil.which("sshpass")
            if not sshpass:
                self.close()
                raise RuntimeError("SSH password authentication requires sshpass")
            self.environment["SSHPASS"] = password
            self.command = [sshpass, "-e"] + self.command
        temporary = (
            self.run("if command -v jbroot >/dev/null 2>&1; then jbroot /var/tmp; fi")
            .decode("utf-8")
            .strip()
        )
        self.ps = "/rootfs/bin/ps" if temporary else "ps"
        if temporary and not temporary.startswith("/"):
            self.close()
            raise RuntimeError("jbroot returned a non-absolute temporary directory")
        # Native programs do not use the bootstrap shell's virtual filesystem.
        temporary = temporary or "/var/tmp"
        self.directory = temporary + "/fp-retrieve-" + secrets.token_hex(8)
        self.trigger_directory = temporary + "/fp-trigger-" + secrets.token_hex(8)
        self.run("umask 077; mkdir " + shlex.quote(self.directory))
        self.run("mkdir -m 755 " + shlex.quote(self.trigger_directory))

    def run(self, command: str, data: bytes | None = None) -> bytes:
        remote_command, input_data = self.wrapped_command(command, data)
        attempts = 6 if "SSHPASS" in self.environment else 1
        for attempt in range(attempts):
            result = subprocess.run(
                self.command + [remote_command],
                input=input_data,
                capture_output=True,
                env=self.environment,
                timeout=120,
                check=False,
            )
            if result.returncode == 0:
                return result.stdout
            message = (result.stdout + result.stderr).decode("utf-8", "replace")
            authentication_failure = result.returncode == 255 and (
                not message.strip()
                or "Permission denied" in message
                or "UNIX authentication refused" in message
                or "kex_exchange_identification" in message
            )
            if authentication_failure and attempt + 1 < attempts:
                time.sleep(0.6)
                continue
            break
        if result.returncode:
            if "kex_exchange_identification" in message or "Connection reset" in message:
                message = (
                    "USB 端口已建立，但手机端 SSH 服务没有运行。"
                    "请先在越狱工具或包管理器里启动 OpenSSH/Dropbear。"
                )
            elif self.sudo_password and (
                "Sorry, try again" in message or "incorrect password" in message
            ):
                message = (
                    "Dopamine 的 mobile 密码不正确。请在 Dopamine 设置中"
                    "重新修改 “mobile” 密码后再试。"
                )
            elif not message.strip():
                message = (
                    "SSH 认证被手机拒绝或 OpenSSH 没有响应。请重新打开"
                    "越狱 SSH，并确认登录账户和密码。"
                )
            raise RuntimeError(
                f"device command failed ({result.returncode}): {message}"
            )
        return result.stdout

    def wrapped_command(
        self, command: str, data: bytes | None = None
    ) -> tuple[str, bytes | None]:
        if not self.sudo_password:
            return command, data
        remote_command = (
            "sudo -S -p '' -- /var/jb/usr/bin/sh -c "
            + shlex.quote(command)
        )
        return (
            remote_command,
            self.sudo_password.encode("utf-8") + b"\n" + (data or b""),
        )

    def popen(
        self,
        command: str,
        *,
        stdin=None,
        stdout=None,
        stderr=None,
    ) -> subprocess.Popen:
        remote_command, password_input = self.wrapped_command(command)
        if password_input is None:
            return subprocess.Popen(
                self.command + [remote_command],
                stdin=stdin,
                stdout=stdout,
                stderr=stderr,
                env=self.environment,
            )
        process = subprocess.Popen(
            self.command + [remote_command],
            stdin=subprocess.PIPE,
            stdout=stdout,
            stderr=stderr,
            env=self.environment,
        )
        if process.stdin is None:
            process.terminate()
            raise RuntimeError("SSH process stdin unavailable")
        process.stdin.write(password_input)
        process.stdin.flush()
        process.stdin.close()
        process.stdin = None
        return process

    def processes(self) -> bytes:
        return self.run(shlex.quote(self.ps) + " -e -o pid,comm")

    def path(self, name: str) -> str:
        if not re.fullmatch(r"[a-zA-Z0-9_.-]+", name):
            raise ValueError("invalid remote filename")
        return self.directory + "/" + name

    def write(self, name: str, source: bytes | Path, executable: bool = False) -> str:
        path = self.path(name)
        data = source.read_bytes() if isinstance(source, Path) else source
        self.run("umask 077; cat > " + shlex.quote(path), data)
        if executable:
            self.run("chmod 700 " + shlex.quote(path))
        return path

    def read(self, path: str) -> bytes:
        return self.run("cat " + shlex.quote(path))

    def cleanup(self) -> None:
        try:
            self.run(
                "rm -r -- "
                + shlex.quote(self.directory)
                + " "
                + shlex.quote(self.trigger_directory)
            )
        finally:
            self.close()

    def close(self) -> None:
        if Path(self.control_path).exists():
            subprocess.run(
                [
                    "ssh",
                    "-S",
                    self.control_path,
                    "-O",
                    "exit",
                    "127.0.0.1",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=2,
                check=False,
            )
            try:
                Path(self.control_path).unlink()
            except FileNotFoundError:
                pass
        if self.tunnel is not None and self.tunnel.poll() is None:
            self.tunnel.terminate()
            self.tunnel.wait(timeout=3)
