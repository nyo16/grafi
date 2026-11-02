#!/usr/bin/env bash
# Build igraph from its SHA-256-verified release tarball and install it.
#
#   build-igraph.sh static|shared PREFIX
#
# One configuration for CI (shared) and the precompiled artefacts (static):
# internal maths libraries, thread-local error handling (the NIF relies on
# it), and no GLPK, GraphML, OpenMP or Infomap (unused by grafi).
# Runs on Linux, macOS and inside the manylinux container.
set -euo pipefail

mode=${1:?usage: build-igraph.sh static|shared PREFIX}
prefix=${2:?usage: build-igraph.sh static|shared PREFIX}

case "$mode" in
  static) shared=OFF ;;
  shared) shared=ON ;;
  *) echo "unknown mode: $mode" >&2; exit 2 ;;
esac

# shellcheck source=.github/igraph.env
source "$(dirname "$0")/../igraph.env"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

curl -fsSL -o "$work/igraph.tar.gz" \
  "https://github.com/igraph/igraph/releases/download/${IGRAPH_VERSION}/igraph-${IGRAPH_VERSION}.tar.gz"

if command -v sha256sum >/dev/null; then
  echo "${IGRAPH_SHA256}  $work/igraph.tar.gz" | sha256sum -c -
else
  echo "${IGRAPH_SHA256}  $work/igraph.tar.gz" | shasum -a 256 -c -
fi

tar -xzf "$work/igraph.tar.gz" -C "$work"

cmake -S "$work/igraph-${IGRAPH_VERSION}" -B "$work/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS="$shared" -DBUILD_TESTING=OFF \
  -DIGRAPH_GLPK_SUPPORT=OFF -DIGRAPH_GRAPHML_SUPPORT=OFF -DIGRAPH_OPENMP_SUPPORT=OFF \
  -DIGRAPH_INFOMAP_SUPPORT=OFF -DIGRAPH_ENABLE_TLS=ON \
  -DIGRAPH_USE_INTERNAL_BLAS=ON -DIGRAPH_USE_INTERNAL_LAPACK=ON \
  -DIGRAPH_USE_INTERNAL_ARPACK=ON -DIGRAPH_USE_INTERNAL_GMP=ON \
  -DIGRAPH_USE_INTERNAL_PLFIT=ON
cmake --build "$work/build" --parallel
cmake --install "$work/build"

# Licence texts for release artefacts: igraph's own, plus those of the
# vendored code compiled in (GLPK and Infomap are disabled above).
src="$work/igraph-${IGRAPH_VERSION}"
licenses="$prefix/share/licenses/igraph"
mkdir -p "$licenses"
cp "$src/COPYING" "$src/AUTHORS" "$src/doc/html/igraph-Licenses.html" "$licenses/"
for f in vendor/cs/License.txt vendor/f2c/Notice vendor/pcg/LICENSE.txt vendor/qhull/COPYING.txt; do
  mkdir -p "$licenses/$(dirname "$f")"
  cp "$src/$f" "$licenses/$f"
done
