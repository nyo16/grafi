#!/usr/bin/env bash
# Check a packed NIF artefact before it can be published.
#
#   check-nif-artefact.sh ARCHIVE
#
# - nif_init is the only exported symbol;
# - Linux: needs at most GLIBC_2.28 and GLIBCXX_3.4.25 (manylinux_2_28, so
#   RHEL 8 and newer can load it);
# - macOS: the minimum macOS version equals MACOSX_DEPLOYMENT_TARGET;
# - no libigraph dependency (igraph is linked statically);
# - the NOTICE, GPL-3.0, Apache-2.0 and igraph licence files are included.
set -euo pipefail

archive=${1:?usage: check-nif-artefact.sh ARCHIVE}
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
tar -xzf "$archive" -C "$dir"
so="$dir/grafi_nif.so"
ls -la "$dir"

fail() { echo "check failed: $*" >&2; exit 1; }

# Highest version among "PREFIX_x.y[.z]" tokens on stdin (empty if none;
# grep finding nothing must not trip pipefail).
max_version() { { grep -oE "$1_[0-9.]+" || true; } | sed "s/^$1_//" | sort -V | tail -1; }

for f in grafi_nif.NOTICE grafi_nif.GPL-3.0-or-later.txt grafi_nif.Apache-2.0.txt \
  grafi_nif.licenses/igraph/COPYING; do
  [ -s "$dir/$f" ] || fail "missing $f"
done

# true if $1 <= $2 in version order.
version_le() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }

case "$(uname -s)" in
  Darwin)
    exports=$(nm -gU "$so" | awk '{print $NF}')
    [ "$exports" = "_nif_init" ] || fail "unexpected exports: $(echo "$exports" | tr '\n' ' ')"
    : "${MACOSX_DEPLOYMENT_TARGET:?}"
    minos=$(otool -l "$so" | awk '/LC_BUILD_VERSION/ {b=1} b && /minos/ {print $2; exit}')
    [ "$minos" = "$MACOSX_DEPLOYMENT_TARGET" ] ||
      fail "minos is $minos, expected $MACOSX_DEPLOYMENT_TARGET"
    deps=$(otool -L "$so" | tail -n +2)
    echo "$deps"
    ! echo "$deps" | grep -q igraph || fail "links libigraph dynamically"
    echo "OK: exports _nif_init only; minos $minos"
    ;;
  Linux)
    exports=$(nm -D --defined-only "$so" | awk '{print $NF}')
    [ "$exports" = "nif_init" ] || fail "unexpected exports: $(echo "$exports" | tr '\n' ' ')"
    needs=$(objdump -T "$so")
    glibc=$(echo "$needs" | max_version GLIBC)
    glibcxx=$(echo "$needs" | max_version GLIBCXX)
    version_le "${glibc:-0}" 2.28 || fail "needs GLIBC_$glibc (> 2.28)"
    version_le "${glibcxx:-0}" 3.4.25 || fail "needs GLIBCXX_$glibcxx (> 3.4.25)"
    deps=$(objdump -p "$so" | awk '/NEEDED/ {print $2}')
    echo "$deps"
    ! echo "$deps" | grep -q igraph || fail "links libigraph dynamically"
    echo "OK: exports nif_init only; GLIBC <= ${glibc:-none}, GLIBCXX <= ${glibcxx:-none}"
    ;;
  *)
    fail "unsupported OS"
    ;;
esac
