ZIG_OUT_LIB := "zig-out/lib"
PY_PKG := "python/hypergraphz"

# Build the shared library
build:
    zig build lib -Doptimize=ReleaseFast

# Copy the shared library into the Python package directory, then sync deps
install-py: build
    cp {{ZIG_OUT_LIB}}/libhypergraphz.so {{PY_PKG}}/libhypergraphz.so 2>/dev/null || \
    cp {{ZIG_OUT_LIB}}/libhypergraphz.dylib {{PY_PKG}}/libhypergraphz.dylib 2>/dev/null || \
    cp {{ZIG_OUT_LIB}}/hypergraphz.dll {{PY_PKG}}/hypergraphz.dll 2>/dev/null || \
    (echo "No shared library found in {{ZIG_OUT_LIB}}" && exit 1)
    uv sync

# Run Zig tests
test-zig:
    zig build test --summary all

# Run Python tests (requires install-py first)
test-py:
    uv run pytest tests-python/ -v

# Run all tests
test: test-zig test-py

# Lint and format check Python
lint:
    uv run ruff check python/ tests-python/
    uv run ruff format --check python/ tests-python/

# Format Python in-place
fmt:
    uv run ruff format python/ tests-python/
    uv run ruff check --fix python/ tests-python/

# Run Zig benchmarks
bench-zig:
    zig build bench

# Run Python benchmarks (pyperf — statistical, mirrors Zig output)
bench-py:
    uv run python bench-python/bench_pyperf.py

# Run Python benchmarks with pytest-benchmark (quick table output)
bench-pytest:
    uv run pytest bench-python/bench_pytest.py -v --benchmark-only

# Build a platform wheel locally (runs hatch_build.py hook, which compiles Zig)
wheel:
    uv run python -m cibuildwheel --platform auto

# Tag and push a release — triggers the CI pipeline which builds wheels and publishes to PyPI
# Usage: just release 0.2.0
release version:
    scripts/release.sh {{version}}

# Remove build artifacts
clean:
    rm -rf zig-out .zig-cache
    rm -f {{PY_PKG}}/libhypergraphz.so {{PY_PKG}}/libhypergraphz.dylib {{PY_PKG}}/hypergraphz.dll
