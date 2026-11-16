# Releasing

Releases are built by GitHub Actions (`.github/workflows/release.yml`) on the `macos-26`
runner with Xcode 26.6. Pushing a tag that starts with `v` builds `dist/ClaudeUsage.zip`
with that version and attaches it to the GitHub release of the same name.

## A new version

1. Merge everything for the release into `main`.
2. Tag it and push the tag:

   ```sh
   git tag v0.2.0
   git push origin v0.2.0
   ```

3. The workflow runs the tests, builds the universal app with `VERSION=0.2.0`, checks that
   the app's version matches the tag, and creates the release with generated notes and
   `ClaudeUsage.zip` attached. Edit the notes on GitHub afterwards if you like.

The in-app update check compares the app's version with the latest release's tag, so every
release needs a higher version number than the last.

## Replacing the zip of an existing release

Move the tag and force-push it. The workflow sees the release already exists and only
replaces `ClaudeUsage.zip`; the notes are left alone.

```sh
git tag -f v0.1.0
git push -f origin v0.1.0
```

## By hand (if Actions is unavailable)

```sh
VERSION=0.2.0 ./build.sh dist
gh release create v0.2.0 dist/ClaudeUsage.zip --generate-notes
# or, for an existing release:
gh release upload v0.2.0 dist/ClaudeUsage.zip --clobber
```

Keep the asset name `ClaudeUsage.zip`: the README's download link, `install.sh` and the
update check all rely on it.
