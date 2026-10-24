#!/usr/bin/env python3
"""Report errors hidden in successful DNF scriptlets for one build run."""

import collections
import pathlib
import re
import sys


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: audit-fedora44-build-log.py BUILD.LOG RUN_ID", file=sys.stderr)
        return 2
    log = pathlib.Path(sys.argv[1])
    marker = f"===== UKE BUILD RUN {sys.argv[2]} ====="
    lines = log.read_text(errors="replace").splitlines()
    try:
        start = len(lines) - 1 - lines[::-1].index(marker)
    except ValueError:
        print("build log audit: current run marker is missing", file=sys.stderr)
        return 1

    # These scriptlet errors are tied to artifacts checked by the rootfs audit.
    # Any new error in a DNF scriptlet blocks publication pending investigation.
    expected = {
        "Failed to write database /etc/udev/hwdb.bin: Function not implemented",
        "Failed to preset unit: Unit systemd-tmpfiles-clear.service does not exist",
        "Failed to preset unit: Unit plasma-kded.service does not exist",
        "Failed to open file /usr/lib/systemd/catalog/dbus-broker-launch.catalog: No such file or directory",
        "Failed to import file '/usr/lib/systemd/catalog/dbus-broker-launch.catalog': No such file or directory",
        "Failed to update catalog: No such file or directory",
    }
    seen = collections.Counter()
    unexpected = []
    in_scriptlet_output = False
    for number, line in enumerate(lines[start + 1 :], start + 2):
        if line == ">>> Scriptlet output:":
            in_scriptlet_output = True
            continue
        if line == ">>> " or not line.startswith(">>> "):
            in_scriptlet_output = False
            continue
        if line.startswith((">>> Running ", ">>> Finished ")):
            in_scriptlet_output = False
            continue
        if not in_scriptlet_output:
            continue
        message = line[4:]
        if not re.search(r"\b(failed|error|fatal|cannot|not implemented)\b", message, re.I):
            continue
        if message in expected:
            seen[message] += 1
        elif re.fullmatch(
            r"modprobe: FATAL: Module i2c-dev not found in directory /lib/modules/[A-Za-z0-9._+-]+",
            message,
        ):
            seen["i2c-dev host kernel mismatch"] += 1
        else:
            unexpected.append((number, message))
    for message, count in sorted(seen.items()):
        print(f"build log audit: known installroot warning ({count}): {message}")
    for number, message in unexpected:
        print(f"build log audit: unreviewed scriptlet error at line {number}: {message}", file=sys.stderr)
    if unexpected:
        return 1
    print("build log audit: no unreviewed DNF scriptlet errors in this run")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
