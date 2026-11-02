#!/usr/bin/env bash
# Build the release NIF (static igraph) into OUT_DIR/priv/grafi_nif.so.
#
#   build-release-nif.sh OUT_DIR
#
# Linux: everything runs inside manylinux_2_28 (glibc 2.28), so the
# artefact loads on RHEL 8+, Debian 11+ and Ubuntu 20.04+. The workspace and
# the ERTS headers are mounted at their host paths and the container runs as
# the host user, so the outputs are ordinary files in the workspace.
# macOS: native build; MACOSX_DEPLOYMENT_TARGET (from the caller) sets the
# minimum macOS version for both igraph and the NIF.
#
# Needs: `mix deps.get` done (deps/fine), `erl` on PATH (the build OTP's
# ERTS headers decide the artefact's NIF version).
set -euo pipefail

out=${1:?usage: build-release-nif.sh OUT_DIR}
out=$(cd "$(dirname "$out")" && pwd)/$(basename "$out")
root=$(cd "$(dirname "$0")/../.." && pwd)
igraph_prefix="$out/igraph"

erts_include=$(erl -noshell -eval \
  'io:format("~s/erts-~s/include", [code:root_dir(), erlang:system_info(version)]), halt().')
fine_include="$root/deps/fine/c_include"
test -f "$fine_include/fine.hpp" || { echo "run mix deps.get first" >&2; exit 1; }

# The commands to run in the build environment.
build_cmds=$(cat <<EOF
set -euo pipefail
cd "$root"
.github/scripts/build-igraph.sh static "$igraph_prefix"
make -B MIX_APP_PATH="$out" IGRAPH_DIR="$igraph_prefix" IGRAPH_STATIC=1 GRAFI_REQUIRE_NIF=1 \
  ERTS_INCLUDE_DIR="$erts_include" FINE_INCLUDE_DIR="$fine_include"
EOF
)

mkdir -p "$out"

case "$(uname -s)" in
  Linux)
    case "$(uname -m)" in
      x86_64) image="quay.io/pypa/manylinux_2_28_x86_64@sha256:7e41b1c7fd64dfc69703a1124b43c404382973ee06ec5d764b85c34d2221fded" ;;
      aarch64) image="quay.io/pypa/manylinux_2_28_aarch64@sha256:54b271d9562a3686298880df05367909e949ed317e7b1b79b59c696d75f78676" ;;
      *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
    esac
    erts_root=$(dirname "$(dirname "$erts_include")")
    docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp \
      -v "$root:$root" -v "$out:$out" -v "$erts_root:$erts_root:ro" \
      "$image" bash -c "$build_cmds"
    ;;
  Darwin)
    : "${MACOSX_DEPLOYMENT_TARGET:?set MACOSX_DEPLOYMENT_TARGET for release builds}"
    bash -c "$build_cmds"
    ;;
  *)
    echo "unsupported OS $(uname -s)" >&2
    exit 1
    ;;
esac

test -f "$out/priv/grafi_nif.so"
