# Releasing agyx

Maintainer notes. A release is one checked command: `scripts/release.sh VERSION`.

## Version policy

0.x. Bump the patch number for fixes and the minor number for behaviour changes (a changed prompt, layout, or file the user can see).

## Steps

1. Bump `AGYX_VERSION` in `runtime/sync.sh` and the tag in the `url` line of `Formula/agyx.rb` (the sha256 stays the placeholder; the script writes the real one into the tap copy only). Commit on `main` and push.
2. Dry run, which runs every check (including the tests and shellcheck) and prints the commands without running them:

   ```sh
   scripts/release.sh --dry-run 0.1.3
   ```

3. For real:

   ```sh
   scripts/release.sh 0.1.3
   ```

   It refuses unless: you are on `main`; `VERSION` equals `AGYX_VERSION` and the tag in the formula url; the tag does not exist; the tap checkout (`AGYX_TAP_DIR`, default `../homebrew-tap`) exists; tests and shellcheck pass. It checks nothing else. It then asks `Release VERSION? [y/N]`, tags `vVERSION` (annotated), pushes `main` and the tag (retrying over HTTPS when SSH fails), runs `gh release create vVERSION --generate-notes`, downloads the tag tarball, writes the formula with the real sha256 into the tap, commits `agyx VERSION`, pushes, and runs `brew update && brew audit --strict --online iamdin/tap/agyx`. It never installs agyx on the machine.

Your own checklist, because the script does not check it: working tree clean and `main` pushed (the tag is made on your local `main`); commits use your noreply email (`git log --format='%h %ae %ce' vPREV..HEAD`); README and docs are up to date; the tap checkout is clean and current.

Set up yourself first: `gh auth login` with a token that may create releases on `iamdin/agyx` (the `repo` scope, or fine-grained Contents: write), push access to both `iamdin/agyx` and `iamdin/homebrew-tap`, and a clone of the tap next to the repo.

The script's own tests: `sh test/release.sh` (temporary repos, stubbed `gh`, `brew`, `curl`, no network). CI runs them with `test/run.sh` on macOS.

## Verify on a second machine

```sh
brew update && brew upgrade agyx && agyx --version
```

## Roll back a bad release

Re-point the tap formula to the previous tag: restore its `url` and `sha256` from the tap history (`git revert` the `agyx VERSION` commit in the tap) and push, then `brew update && brew upgrade agyx` on the machines that took the bad version. Never delete or move a pushed tag; fix forward with a new patch version.
