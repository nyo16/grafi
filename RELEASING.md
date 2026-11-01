# Releasing Grafi

Grafi ships as a Hex package plus precompiled NIF artefacts attached to the
matching GitHub release. Consumers download the artefact for their target and
verify it against `checksum.exs` in the package; on any other target (or if
the download fails) the NIF is built from source, which needs igraph >= 1.0,
and without igraph Grafi runs in pure Elixir.

## One-time: licence sign-off (required before the first upload)

The precompiled artefacts statically link igraph, so each artefact is
distributed under GPL-2.0-or-later (see `NOTICE`). The `upload` job in
`.github/workflows/release.yml` does nothing until this is signed off.

1. Have `NOTICE` and the README "Third-party licenses" section reviewed.
2. Confirm each GitHub release will carry the corresponding-source pointer
   from `NOTICE` (igraph tarball URL and the grafi tag).
3. Set the repository variable `RELEASE_LICENSE_APPROVED` to `true`
   (Settings → Secrets and variables → Actions → Variables).

## Per release

1. **Prepare.** Bump `@version` in `mix.exs`, move the CHANGELOG
   `[Unreleased]` entries under the new version, merge to the default branch.
2. **Dry run (optional).** Run the Release workflow with *Run workflow*
   (`workflow_dispatch`). It builds and smoke-tests all four targets without
   uploading anything.
3. **Tag.** `git tag vX.Y.Z && git push origin vX.Y.Z`. The Release workflow:
   - builds a static igraph and the NIF on each native runner
     (x86_64/aarch64 Linux, x86_64/aarch64 macOS) with OTP 28, so the
     artefacts are tagged NIF 2.17 and load on OTP 26-29;
   - checks that the NIF exports only `nif_init`;
   - smoke-tests each artefact in a consumer app without igraph;
   - uploads `grafi-nif-*.tar.gz` and their `.sha256` files to the release.
4. **Checksums.** Once the release is published with all eight files:

   ```bash
   mix elixir_make.checksum --all --ignore-unavailable
   git add checksum.exs && git commit -m "checksum.exs for vX.Y.Z"
   ```

   `checksum.exs` must list all four targets. `--ignore-unavailable` only
   tolerates a target whose build was intentionally dropped; check the
   output before committing.
5. **Verify the package.**

   ```bash
   mix hex.build --unpack
   ls grafi-X.Y.Z/   # checksum.exs, NOTICE, CHANGELOG.md, LICENSE present
   rm -rf grafi-X.Y.Z grafi-X.Y.Z.tar
   ```

6. **Publish.** `mix hex.publish`.

## Supported targets and runtimes

| Target | Runner | Notes |
|---|---|---|
| `x86_64-linux-gnu` | `ubuntu-22.04` | glibc >= 2.35 |
| `aarch64-linux-gnu` | `ubuntu-22.04-arm` | glibc >= 2.35 |
| `aarch64-apple-darwin` | `macos-15` | |
| `x86_64-apple-darwin` | `macos-15-intel` | last Intel image (GitHub support until Aug 2027) |

Artefacts are tagged with the NIF version of the OTP they were built on:
2.17 for OTP 26-28. OTP 29 (NIF 2.18) loads the 2.17 artefact through
elixir_make's same-major fallback. When raising the minimum OTP, update
`make_precompiler_nif_versions` in `mix.exs` and `OTP_VERSION` in
`release.yml` together.
