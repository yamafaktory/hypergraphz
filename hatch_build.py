"""Custom hatch build hook: compiles the Zig shared library during wheel packaging."""

import shutil
import subprocess
from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface

ROOT = Path(__file__).parent
PKG_DIR = ROOT / "python" / "hypergraphz"
PATTERNS = ("libhypergraphz.so", "libhypergraphz.dylib", "hypergraphz.dll")


class CustomBuildHook(BuildHookInterface):
    def initialize(self, version, build_data):
        if self.target_name == "sdist":
            return

        # CI pre-copies the library before invoking cibuildwheel — nothing to do.
        if any(PKG_DIR.glob(p) for p in PATTERNS):
            build_data["pure_python"] = False
            return

        # Local development: build and copy.
        lib_dir = ROOT / "zig-out" / "lib"
        subprocess.run(["zig", "build", "lib", "-Doptimize=ReleaseFast"], check=True, cwd=ROOT)

        copied = False
        for pattern in PATTERNS:
            for lib in lib_dir.glob(pattern):
                shutil.copy2(lib, PKG_DIR / lib.name)
                copied = True

        if not copied:
            raise RuntimeError(f"No shared library found in {lib_dir}")

        build_data["pure_python"] = False
