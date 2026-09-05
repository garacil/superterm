## macOS

Native builds for macOS (same VERSION sources):

- `superterm-VERSION-macos-arm64.tar.gz` — Apple Silicon (M1/M2/M3/M4)
- `superterm-VERSION-macos-universal.tar.gz` — universal (Intel + Apple Silicon)

Install:

```sh
tar xzf superterm-VERSION-macos-arm64.tar.gz
cd superterm-VERSION
xattr -dr com.apple.quarantine superterm   # unsigned build: clear Gatekeeper quarantine
sudo install -m 0755 superterm /usr/local/bin/superterm   # optional: put it on PATH
./superterm
```

Notes: mouse works in Terminal.app/iTerm2 (enable "Use Option as Meta key" for Alt/menu
shortcuts). Local shells and SSH panes both supported.

<!--
Paste this into the release notes with VERSION replaced, e.g.

    sed "s/VERSION/5.2.2/g" notes-snippet.md >> notes.md
    gh release edit v5.2.2 --repo garacil/superterm --notes-file notes.md

Only add it if the notes do not already contain a "## macOS" heading. Regenerating the
notes from the changelog drops this section, so check after any notes update.
-->
