"""Custom hatch build hook: compiles the Zig shared library during wheel packaging."""

import shutil
import subprocess
from pathlib import Path

from hatchling.builders.hooks.plugin.interface import BuildHookInterface

ROOT = Path(__file__).parent


class CustomBuildHook(BuildHookInterface):
    def initialize(self, version, build_data):
        if self.target_name == "sdist":
            return

        subprocess.run(
            ["zig", "build", "lib", "-Doptimize=ReleaseFast"],
            check=True,
            cwd=ROOT,
        )

        lib_dir = ROOT / "zig-out" / "lib"
        pkg_dir = ROOT / "python" / "hypergraphz"

        copied = False
        for pattern in ("libhypergraphz.so", "libhypergraphz.dylib", "hypergraphz.dll"):
            for lib in lib_dir.glob(pattern):
                dst = pkg_dir / lib.name
                shutil.copy2(lib, dst)
                build_data["artifacts"].append(str(dst))
                copied = True

        if not copied:
            raise RuntimeError(f"No shared library found in {lib_dir}")

        build_data["pure_python"] = False
