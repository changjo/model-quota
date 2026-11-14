#!/usr/bin/env python3
"""Print the app's release version from Info.plist for the release workflow.

Reads CFBundleShortVersionString from the given plist (default
Resources/Info.plist) and prints it if it has the X.Y.Z form. Exits 1 with a
message on stderr otherwise, so CI never releases a malformed version.
"""
import plistlib
import re
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "Resources/Info.plist"


def fail(reason):
    print(f"release-version: {reason}", file=sys.stderr)
    sys.exit(1)


try:
    with open(path, "rb") as file:
        info = plistlib.load(file)
except (OSError, plistlib.InvalidFileException) as error:
    fail(f"cannot read {path}: {error}")

version = info.get("CFBundleShortVersionString")
if version is None:
    fail(f"CFBundleShortVersionString is missing in {path}")
if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
    fail(f"CFBundleShortVersionString {version!r} in {path} is not X.Y.Z")
print(version)
