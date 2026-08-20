#!/usr/bin/env sh
# Build the scratch consumer against this tree as a consumer would receive it.
# Run from the repo root (`just consumer-smoke`). See dev.md "Packaging".
set -eu
here=$(dirname "$0")
root=$(pwd)
# A stable dir OUTSIDE the tree. Outside, because a path fetch walks every
# directory of the source, so a scratch dir inside it would be fetched into
# itself. Stable, because the consumer's compile cache lives there: cold is
# ~6s, warm well under a second. zig-pkg/ is wiped so every run re-packs the
# tree through `.paths`.
dir=${TMPDIR:-/tmp}/csar-consumer-smoke
rm -rf "$dir/zig-pkg"
mkdir -p "$dir"
cp "$here/build.zig" "$here/build.zig.zon" "$dir"
cp examples/basic.zig "$dir/main.zig"
cd "$dir"
zig fetch --save=csar "$root"
# Files, not dirs: a path fetch leaves empty directory skeletons behind.
echo "shipped:"; (cd zig-pkg/csar-*/ && find . -type f | sort | sed 's|^./|  |')
zig build run
