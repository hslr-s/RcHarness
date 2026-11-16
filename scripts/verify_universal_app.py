"""Reject incomplete Universal bundles or binaries requiring macOS newer than 14."""
import plistlib
import re
import subprocess
import sys
from pathlib import Path


def verify(app):
    app = Path(app).resolve()
    with (app / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info["LSMinimumSystemVersion"] != "14.0":
        raise ValueError("The application must declare macOS 14.0 as its minimum")

    required = {
        app / "Contents/MacOS/RcHarness",
        app / "Contents/PlugIns/RcHarnessMicrophone.driver/Contents/MacOS/RcHarnessMicrophone",
    }
    # Inspect embedded Sparkle helpers too; skip framework symlink duplicates.
    magic = {bytes.fromhex(value) for value in (
        "feedface", "cefaedfe", "feedfacf", "cffaedfe",
        "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
    )}
    binaries = set()
    for path in app.rglob("*"):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as source:
                if source.read(4) in magic:
                    binaries.add(path.resolve())
    if not required <= binaries:
        raise ValueError("Missing application or HAL driver executable")

    for binary in sorted(binaries):
        architectures = subprocess.check_output(
            ["xcrun", "lipo", "-archs", str(binary)], text=True
        ).split()
        if set(architectures) != {"arm64", "x86_64"}:
            raise ValueError(f"Both arm64 and x86_64 are required: {binary}")
        for architecture in architectures:
            build = subprocess.check_output(
                ["xcrun", "vtool", "-arch", architecture, "-show-build", str(binary)], text=True
            )
            versions = re.findall(r"^\s*minos\s+(\d+(?:\.\d+)*)\s*$", build, re.MULTILINE)
            if len(versions) != 1:
                raise ValueError(f"Missing minimum system version: {binary} ({architecture})")
            minimum = tuple(int(part) for part in versions[0].split("."))
            minimum = (minimum + (0, 0))[:3]
            if minimum > (14, 0, 0) or (binary in required and minimum != (14, 0, 0)):
                raise ValueError(f"Unexpected minimum macOS {versions[0]}: {binary} ({architecture})")
    print(f"Verified {len(binaries)} Universal executables compatible with macOS 14")


if __name__ == "__main__":
    verify(sys.argv[1])
