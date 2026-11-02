#!/usr/bin/env bash
# Pack OUT_DIR/priv/grafi_nif.so into the archive elixir_make downloads.
#
#   pack-nif-artefact.sh TARGET OUT_DIR DEST_DIR
#
# Name: grafi-nif-<NIF version of the running OTP>-<TARGET>-<mix version>.tar.gz
# Format: erl_tar, compressed, files at the root (what elixir_make's
# precompile task produces). Since the artefact statically includes igraph,
# the archive also carries NOTICE, the GPL-3.0 and Apache-2.0 texts, and
# igraph's licence files (grafi_nif.licenses/igraph, from build-igraph.sh).
# Writes DEST_DIR/<name> and DEST_DIR/<name>.sha256 ("<sha256>  <name>").
set -euo pipefail

target=${1:?usage: pack-nif-artefact.sh TARGET OUT_DIR DEST_DIR}
out=${2:?usage: pack-nif-artefact.sh TARGET OUT_DIR DEST_DIR}
dest=${3:?usage: pack-nif-artefact.sh TARGET OUT_DIR DEST_DIR}
root=$(cd "$(dirname "$0")/../.." && pwd)

nif=$(erl -noshell -eval 'io:format("~s", [erlang:system_info(nif_version)]), halt().')
version=$(sed -n 's/^  @version "\(.*\)"$/\1/p' "$root/mix.exs")
test -n "$version" || { echo "could not read @version from mix.exs" >&2; exit 1; }
# Artefacts carry the release version; between releases mix.exs says
# X.Y.Z-dev (a tag build never does: release.yml checks tag == @version).
version=${version%-dev}
name="grafi-nif-${nif}-${target}-${version}.tar.gz"

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp "$out/priv/grafi_nif.so" "$stage/grafi_nif.so"
cp "$root/NOTICE" "$stage/grafi_nif.NOTICE"
cp "$root/LICENSES/GPL-3.0-or-later.txt" "$stage/grafi_nif.GPL-3.0-or-later.txt"
cp "$root/LICENSE" "$stage/grafi_nif.Apache-2.0.txt"
mkdir -p "$stage/grafi_nif.licenses"
cp -R "$out/igraph/share/licenses/igraph" "$stage/grafi_nif.licenses/igraph"

mkdir -p "$dest"
dest=$(cd "$dest" && pwd)
(cd "$stage" && erl -noshell -eval "
  ok = erl_tar:create(\"$dest/$name\",
         [\"grafi_nif.so\", \"grafi_nif.NOTICE\", \"grafi_nif.GPL-3.0-or-later.txt\",
          \"grafi_nif.Apache-2.0.txt\", \"grafi_nif.licenses\"],
         [compressed]),
  halt().")

if command -v sha256sum >/dev/null; then
  sum=$(sha256sum "$dest/$name" | cut -d' ' -f1)
else
  sum=$(shasum -a 256 "$dest/$name" | cut -d' ' -f1)
fi
printf '%s  %s\n' "$sum" "$name" > "$dest/$name.sha256"
echo "packed $dest/$name ($sum)"
