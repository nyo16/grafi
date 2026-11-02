# Releasing Grafi

Grafi ships as a Hex package plus precompiled NIF artefacts attached to the
matching GitHub release. Consumers download the artefact for their target and
verify it against `checksum.exs` in the package; on any other target (or if
the download fails) the NIF is built from source, which needs igraph >= 1.0,
and without igraph Grafi runs in pure Elixir.

Between releases `@version` in `mix.exs` ends in `-dev`. elixir_make always
builds a `-dev` version from source, so development copies never pick up a
published artefact.

## One-time setup (before the first upload)

1. **Licence sign-off.** The artefacts statically link igraph and are
   distributed under GPL-3.0-or-later (see `NOTICE`; Apache-2.0 code combined
   with GPL code is GPL-3.0-compatible only). Have `NOTICE`, the README
   "Third-party licenses" section and the release notes written by
   `release.yml` reviewed. Then set the repository variable
   `RELEASE_LICENSE_APPROVED` to `true` (Settings → Secrets and variables →
   Actions → Variables). Until then the `upload` job does nothing.
2. **Protected environment.** Create the environment `release` (Settings →
   Environments) with required reviewers and restrict it to `v*` tags. The
   upload job runs in it, so every release needs an explicit approval.
3. **Immutable releases.** Enable immutable releases for the repository
   (Settings → General → Releases), so published assets cannot be replaced.
   The workflow never uses `--clobber`; a bad artefact means a new patch
   version, never a re-upload under the same tag.

## Per release

1. **Prepare.** Set `@version` in `mix.exs` to `X.Y.Z` (drop `-dev`), move the
   CHANGELOG `[Unreleased]` entries under the new version, and merge to the
   default branch. The Release workflow's PR dry run builds, checks and
   smoke-tests all four targets.
2. **Tag.** `git tag vX.Y.Z && git push origin vX.Y.Z`. The Release workflow:
   - fails if the tag doesn't equal `v` + `@version`;
   - builds a static igraph and the NIF per target: Linux in manylinux_2_28
     (glibc 2.28) on x86_64/aarch64, macOS natively with
     `MACOSX_DEPLOYMENT_TARGET` 11.0 (arm64) / 10.15 (x86_64), all on OTP 28,
     so the artefacts are tagged NIF 2.17 and load on OTP 26-29;
   - checks that `nif_init` is the only export and that the platform floor
     (GLIBC <= 2.28, minimum macOS) holds;
   - smoke-tests each artefact in a consumer app without igraph;
   - after approval in the `release` environment: verifies the artefacts,
     writes `checksum.exs` from them (exactly 4 entries), records build
     provenance attestations, and publishes the artefacts, their `.sha256`
     files, `checksum.exs`, `NOTICE` and the igraph source tarball with
     release notes carrying the licence and corresponding-source pointers;
   - finally downloads the published artefact from the release URL as a Hex
     consumer would, on OTP 26 and 29 (Linux) and OTP 28 (macOS).
3. **Checksums.** Fetch the workflow's `checksum.exs` and verify it:

   ```bash
   gh release download vX.Y.Z --pattern 'grafi-nif-*.tar.gz' --pattern checksum.exs --dir /tmp/rel
   for f in /tmp/rel/grafi-nif-*.tar.gz; do gh attestation verify "$f" --repo nyo16/grafi; done
   mix elixir_make.checksum --all --print   # must match /tmp/rel/checksum.exs (4 entries)
   cp /tmp/rel/checksum.exs checksum.exs
   ```

   Commit `checksum.exs` **on top of the tag** (on the default branch, with
   nothing else): `git diff vX.Y.Z HEAD --stat` must list only `checksum.exs`.
4. **Verify the package.**

   ```bash
   mix hex.build --unpack
   ls grafi-X.Y.Z/   # checksum.exs (4 entries), NOTICE, LICENSES/, CHANGELOG.md, LICENSE
   rm -rf grafi-X.Y.Z grafi-X.Y.Z.tar
   ```

5. **Publish.** `mix hex.publish`.
6. **Back to development.** Set `@version` to the next `X.Y.(Z+1)-dev`.

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
