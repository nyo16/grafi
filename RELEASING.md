# Releasing Grafi

Grafi ships as a Hex package plus precompiled NIF artefacts attached to the
matching GitHub release; a `v*` tag publishes both from CI. The artefacts
are GPL-3.0-or-later (static igraph), so consumers download one only after
opting in with
`config :grafi, precompiled_nif: true`, verified against `checksum.exs` in the
package. By default, on any other target, or if the download fails, the NIF
is built from source, which needs igraph >= 1.0, and without igraph Grafi runs
in pure Elixir.

Between releases `@version` in `mix.exs` ends in `-dev`. elixir_make always
builds a `-dev` version from source, so development copies never pick up a
published artefact.

## One-time setup (before the first release)

1. **Enable artefact uploads.** The artefacts statically link igraph and are
   distributed under GPL-3.0-or-later (see `NOTICE`; Apache-2.0 code combined
   with GPL code is GPL-3.0-compatible only), and consumers get them only by
   opting in. When you are ready to publish them, set the repository variable
   `RELEASE_LICENSE_APPROVED` to `true` (Settings → Secrets and variables →
   Actions → Variables). Until then the `upload` job does nothing.
2. **Release environment.** Create the environment `release` (Settings →
   Environments) with yourself as required reviewer and deployments limited
   to `v*` tags. The upload job runs in it, so the GitHub release needs an
   explicit approval.
3. **Hex environment.** Create the environment `hex` the same way and add
   the secret `HEX_API_KEY` to it (a key from `mix hex.user key generate`
   or hex.pm → Keys with permission to publish), not to the repository
   secrets. Only the `publish` job runs in it, so no other job can read the
   key, and Hex publishing needs a second approval.
4. **Immutable releases.** Enable immutable releases for the repository
   (Settings → General → Releases), so published assets cannot be replaced.
   The workflow never uses `--clobber`; a bad artefact means a new patch
   version, never a re-upload under the same tag.

## Per release

1. **Prepare.** Set `@version` in `mix.exs` to `X.Y.Z` (drop `-dev`), move the
   CHANGELOG `[Unreleased]` entries under the new version, and merge to the
   default branch. The Release workflow's PR dry run builds, checks and
   smoke-tests all four targets.
2. **Tag.** `git tag vX.Y.Z && git push origin vX.Y.Z`. The Release workflow:
   - fails if `@version` still ends in `-dev` or the tag doesn't equal
     `v` + `@version`;
   - builds a static igraph and the NIF per target: Linux in manylinux_2_28
     (glibc 2.28) on x86_64/aarch64, macOS natively with
     `MACOSX_DEPLOYMENT_TARGET` 11.0 (arm64) / 10.15 (x86_64), all on OTP 28,
     so the artefacts are tagged NIF 2.17 and load on OTP 26-29;
   - checks that `nif_init` is the only export, that the platform floor
     (GLIBC <= 2.28, minimum macOS) holds, and that the archive carries
     NOTICE, the GPL-3.0 and Apache-2.0 texts and igraph's licence files;
   - smoke-tests each artefact in a consumer app without igraph;
   - after approval in the `release` environment: verifies the artefacts
     (exactly the 4 expected names), writes `checksum.exs` from them, records
     build provenance attestations, and creates the release with everything
     attached in one step (draft, upload, publish): the artefacts, their
     `.sha256` files, `checksum.exs`, `NOTICE` and the igraph source tarball,
     with release notes carrying the licence and corresponding-source
     pointers. An existing release is never reused;
   - downloads the published artefact from the release URL as a Hex
     consumer would, on all four targets (and on OTP 26 and 29 on Linux);
   - finally, after approval in the `hex` environment: re-checks every
     published artefact against the release's `checksum.exs` (exactly 4
     entries) and runs `mix hex.publish --yes` (package and docs) from the
     tag with that `checksum.exs` in the package.

   `publish` runs only when every earlier job succeeded, so a failure stops
   Hex publishing on its own. With immutable releases a published `vX.Y.Z`
   can't be repaired: fix the problem and release `X.Y.(Z+1)` instead. (If
   the release was never created, deleting and re-pushing the tag is fine.)
3. **Before approving `hex`,** check the provenance of what is about to ship:

   ```bash
   gh release download vX.Y.Z --pattern 'grafi-nif-*.tar.gz' --pattern checksum.exs --dir /tmp/rel
   for f in /tmp/rel/grafi-nif-*.tar.gz; do
     gh attestation verify "$f" --repo nyo16/grafi \
       --signer-workflow nyo16/grafi/.github/workflows/release.yml --source-ref refs/tags/vX.Y.Z
   done
   cat /tmp/rel/checksum.exs   # 4 entries, the names consumers request
   ```

4. **Back to development.** In one PR, commit the release's `checksum.exs`
   (a record of what shipped) and set `@version` to the next `X.Y.(Z+1)-dev`.

## Supported targets and runtimes

| Target | Built on | Runs on |
|---|---|---|
| `x86_64-linux-gnu` | `ubuntu-24.04` + manylinux_2_28 container | glibc >= 2.28 |
| `aarch64-linux-gnu` | `ubuntu-24.04-arm` + manylinux_2_28 container | glibc >= 2.28 |
| `aarch64-apple-darwin` | `macos-15` | macOS >= 11.0 |
| `x86_64-apple-darwin` | `macos-15-intel` (last Intel image; GitHub support until Aug 2027) | macOS >= 10.15 |

Artefacts are tagged with the NIF version of the OTP they were built on:
2.17 for OTP 26-28. OTP 29 (NIF 2.18) loads the 2.17 artefact through
elixir_make's same-major fallback. When raising the minimum OTP, update
`make_precompiler_nif_versions` in `mix.exs` and `OTP_VERSION` in
`release.yml` together. The igraph version and SHA-256 live in
`.github/igraph.env` (and are quoted in `NOTICE`).
