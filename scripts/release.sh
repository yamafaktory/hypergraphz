#!/usr/bin/env bash
set -euo pipefail

version="${1:-}"
if [ -z "$version" ]; then
    echo "Usage: $0 <version>  (e.g. $0 0.2.0)"
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "Error: working tree is dirty — commit or stash changes first"
    exit 1
fi

latest=$(git tag --list 'v*' --sort=-version:refname | head -1)
if [ -n "$latest" ]; then
    current=${latest#v}
    if [ "$current" = "$version" ]; then
        echo "Error: v$version already exists"
        exit 1
    fi
    newer=$(printf '%s\n' "$current" "$version" | sort -V | tail -1)
    if [ "$newer" != "$version" ]; then
        echo "Error: v$version is not greater than existing $latest"
        exit 1
    fi
fi

sed -i "s/\.version = \"[^\"]*\"/\.version = \"$version\"/" build.zig.zon
git add build.zig.zon
git commit -m "release $version"

git tag "v$version"
git push origin main "v$version"
