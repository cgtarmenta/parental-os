#!/usr/bin/env python3
"""
Calamares Python job module for parental-os guardian secret provisioning.

Provisions the domain-separated SHA-256 hash of the guardian password into
/etc/parental-os/guardian.hash in the target system.

Resolution priority:
1. /run/parental-os/guardian.hash (from live environment prompt if set).
2. PARENTAL_OS_GUARDIAN_PASSWORD environment variable.
3. Secure random fallback generated via secrets.
"""

import hashlib
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys

DOMAIN_PREFIX = "parental-guard:lan-v1:"
LIVE_HASH_PATH = Path("/run/parental-os/guardian.hash")
TARGET_REL_PATH = Path("etc/parental-os/guardian.hash")


def compute_hash(password: str) -> str:
    """Compute domain-separated SHA-256 hash for a guardian password."""
    payload = (DOMAIN_PREFIX + password).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def is_valid_sha256_hex(val: str) -> bool:
    """Check if string is a 64-character lowercase hex string."""
    if len(val) != 64:
        return False
    return all(c in "0123456789abcdefABCDEF" for c in val)


def get_root_mount_point() -> Path:
    """Retrieve target root mount point from Calamares global storage or environment."""
    try:
        import libcalamares
        if libcalamares.globalstorage.contains("rootMountPoint"):
            rmp = libcalamares.globalstorage.value("rootMountPoint")
            if rmp and os.path.exists(rmp):
                return Path(rmp)
    except Exception:
        pass

    env_rmp = os.environ.get("CALAMARES_ROOT_MOUNT_POINT") or os.environ.get("ROOT")
    if env_rmp and os.path.exists(env_rmp):
        return Path(env_rmp)

    return Path("/")


def resolve_guardian_hash(root_mount_point: Path) -> str:
    """Resolve or compute the 64-character hex guardian hash."""
    # 1. Check live environment hash file, or target root if mounted
    candidate_paths = [LIVE_HASH_PATH]
    if root_mount_point != Path("/"):
        candidate_paths.append(root_mount_point / "run/parental-os/guardian.hash")

    for p in candidate_paths:
        if p.is_file():
            try:
                content = p.read_text(encoding="utf-8").strip()
                if content:
                    if is_valid_sha256_hex(content):
                        return content.lower()
                    return compute_hash(content)
            except OSError:
                pass

    # 2. Check environment variable for direct hash or password
    env_hash = os.environ.get("PARENTAL_OS_GUARDIAN_HASH")
    if env_hash and is_valid_sha256_hex(env_hash.strip()):
        return env_hash.strip().lower()

    env_password = os.environ.get("PARENTAL_OS_GUARDIAN_PASSWORD")
    if env_password:
        return compute_hash(env_password)

    # 3. Generate secure random fallback secret
    random_secret = secrets.token_hex(24)
    return compute_hash(random_secret)


def write_hash_file(path: Path, hash_val: str) -> None:
    """Write hash value to file with mode 0600 and root:root ownership."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.parent / f"{path.name}.tmp.{os.getpid()}"

    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    fd = os.open(str(tmp_path), flags, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(hash_val.strip() + "\n")

    os.chmod(str(tmp_path), 0o600)
    try:
        shutil.chown(str(tmp_path), user="root", group="root")
    except (PermissionError, LookupError, OSError):
        pass

    tmp_path.replace(path)
    os.chmod(str(path), 0o600)
    try:
        shutil.chown(str(path), user="root", group="root")
    except (PermissionError, LookupError, OSError):
        pass


def run():
    """Calamares module entrypoint."""
    root_mount_point = get_root_mount_point()
    hash_val = resolve_guardian_hash(root_mount_point)

    # Sync live hash in /run if not present and writable
    if not LIVE_HASH_PATH.is_file():
        try:
            write_hash_file(LIVE_HASH_PATH, hash_val)
        except OSError:
            pass

    # Write into target root mount point
    if root_mount_point == Path("/"):
        target_file = Path("/") / TARGET_REL_PATH
    else:
        target_file = root_mount_point / TARGET_REL_PATH

    write_hash_file(target_file, hash_val)

    # Restart agent service if running to pick up the new secret
    try:
        subprocess.run(
            ["systemctl", "try-restart", "parental-guard-agent.service"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass

    # Return None on success per Calamares Python job module protocol
    return None


if __name__ == "__main__":
    sys.exit(0 if run() is None else 1)
