#!/usr/bin/env python3
"""Exercise recovery with a fake pmset. Never changes macOS power settings."""
from pathlib import Path
import os
import shlex
import subprocess
import tempfile
import time

SOURCE = Path(__file__).resolve().parents[1] / "Resources/PowerSession.sh"


def wait_for(test, message):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if test():
            return
        time.sleep(0.05)
    raise AssertionError(message)


def check(previous, terminate_host=False, stale=False):
    with tempfile.TemporaryDirectory(prefix="zest power checks ") as directory:
        root = Path(directory)
        log = root / "calls"
        fake = root / "fake pmset"
        fake.write_text("#!/bin/sh\nif [ \"$1\" = -g ]; then printf 'System-wide power settings:\\n SleepDisabled %s\\n' \"$TEST_PREVIOUS\"; else printf '%s\\n' \"$3\" >> \"$TEST_LOG\"; fi\n")
        fake.chmod(0o700)
        script = root / "PowerSession.sh"
        lock = root / "root lock"
        if stale:
            lock.mkdir()
            (lock / "pid").write_text("99999999")
            (lock / "previous").write_text(str(previous))
        text = SOURCE.read_text().replace("/usr/bin/pmset", shlex.quote(str(fake)))
        text = text.replace("lock=/var/run/app.zest.monitor.awake", "lock=" + shlex.quote(str(lock)))
        script.write_text(text)
        lease = root / "lease"
        lease.touch()
        host = subprocess.Popen(["/bin/sleep", "30"]) if terminate_host else None
        env = dict(os.environ, TEST_PREVIOUS=str(previous), TEST_LOG=str(log))
        try:
            subprocess.run(["/bin/sh", str(script), str(host.pid if host else os.getpid()), str(lease)], env=env, check=True)
            prefix = [str(previous), "1"] if stale else ["1"]
            assert log.read_text().splitlines() == prefix, "recover stale watcher and enable once"
            conflict = subprocess.run(["/bin/sh", str(script), str(os.getpid()), str(lease)], env=env, capture_output=True)
            assert conflict.returncode != 0, "reject overlapping power sessions"
            if host:
                host.terminate()
                host.wait(timeout=3)
            else:
                lease.unlink()
            wait_for(lambda: not lock.exists(), "watcher failed to restore and remove lock")
            assert log.read_text().splitlines() == prefix + [str(previous)], "restore original value, including pre-existing awake state"
        finally:
            lease.unlink(missing_ok=True)
            if host and host.poll() is None:
                host.terminate()
                host.wait(timeout=3)
    return 1


if __name__ == "__main__":
    count = check(0) + check(1) + check(0, terminate_host=True) + check(0, stale=True)
    print(f"Passed {count} power-session recovery scenarios (fake pmset only)")
