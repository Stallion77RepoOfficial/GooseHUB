# GooseHUB

A macOS launcher for the Wine, FEX and DXMT Adrenalin forks on Apple Silicon.

Keep one source checkout of each project in the same folder:

```text
Github/
  GooseHUB/
  wine-adrenalin-edition/
  fex-adrenalin-edition/
  dxmt-adrenalin-edition/
```

## Build the app

Use Xcode with the macOS 27 SDK, Swift 6.2 or newer, and the Metal toolchain.

```sh
./build.sh
```

This creates `dist/Goose HUB latest.app` with the launcher and engine installer. Wine, FEX, DXMT, runtime dependencies and MetalGoose are not packaged in this initial app.

## First launch

Open the app and select **Download and Build**. Setup installs missing Homebrew build/media dependencies, fetches the source revisions in `Resources/engine-lock.json`, builds them and verifies the resulting files. The library becomes available after every required component is installed.

The default source folder is `~/Downloads/Github`; another folder can be selected before installation. Existing repositories with local changes are preserved and setup stops with an explanation. These repositories are private; Git must already be authenticated with an account that can read them. Credentials stay with Git's credential helper.

Build products and compiler tools live in `~/Library/Caches/GooseHUB`. The single installed runtime lives in the app's `Contents/Resources/Engines`. There is no staged `Engines/` source-tree copy and no duplicate Wine source snapshot. The app re-signs its resources after installing the compiled engines, so it must be in a location writable by your user.

Setup records source commits and file checksums in the installed runtime manifest. A failed build does not replace a working runtime. Cancel stops the current build; retry reuses completed build work. Rebuilding the launcher creates a fresh installer app.

## Validation

```sh
xcrun swift test --scratch-path "$HOME/Library/Caches/GooseHUB/GooseHUB/swift"
python3 -m unittest discover -s Tests -p 'test_*.py'
```

The source installer is `scripts/install-engines.py`. Its `--local-sources` option is for development; normal setup fetches the pinned GitHub revisions. Installed Windows programs and bottle settings remain in `~/Library/Application Support/GooseHUB`.

The local engine forks remain authoritative. See `ENGINE-POLICY.md`, the component licenses and `Resources/engine-sources.json` for the retained changes and earlier validation.
