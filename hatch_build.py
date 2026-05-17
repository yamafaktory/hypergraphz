"""Custom hatch build hook: compiles the Zig shared library during wheel packaging."""

import shutil
import subprocess
import sys
import sysconfig
from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface

ROOT = Path(__file__).parent
PKG_DIR = ROOT / "python" / "hypergraphz"
PATTERNS = ("libhypergraphz.so", "libhypergraphz.dylib", "hypergraphz.dll")


def _wheel_tag() -> str:
    python_tag = f"cp{sys.version_info.major}{sys.version_info.minor}"
    plat = sysconfig.get_platform().replace("-", "_").replace(".", "_")
    return f"{python_tag}-{python_tag}-{plat}"


class CustomBuildHook(BuildHookInterface):
    def initialize(self, version, build_data):
        if self.target_name == "sdist":
            return

        # CI pre-copies the library before invoking cibuildwheel — nothing to build.
        # Local development: build and copy if missing.
        if not any(PKG_DIR.glob(p) for p in PATTERNS):
            lib_dir = ROOT / "zig-out" / "lib"
            subprocess.run(["zig", "build", "lib", "-Doptimize=ReleaseFast"], check=True, cwd=ROOT)

            copied = False
            for pattern in PATTERNS:
                for lib in lib_dir.glob(pattern):
                    shutil.copy2(lib, PKG_DIR / lib.name)
                    copied = True

            if not copied:
                raise RuntimeError(f"No shared library found in {lib_dir}")

        # Tell hatchling this is a platform wheel. Setting both keys because
        # different hatchling versions look at one or the other.
        build_data["pure_python"] = False
        build_data["tag"] = _wheel_tag()
