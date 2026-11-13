# GooseHUB

A macOS launcher for [Wine](https://github.com/Stallion77RepoOfficial/wine-adrenalin-edition), [FEX](https://github.com/Stallion77RepoOfficial/fex-adrenalin-edition) and [DXMT](https://github.com/Stallion77RepoOfficial/dxmt-adrenalin-edition) Adrenalin, with [MetalGoose](https://github.com/Stallion77RepoOfficial/MetalGoose) scaling.

```text
~/Downloads/Github/
  GooseHUB/
  wine-adrenalin-edition/
  fex-adrenalin-edition/
  dxmt-adrenalin-edition/
  MetalGoose/
```

## Build

Requires Apple Silicon, Xcode with the macOS 27 SDK, Swift 6.2 or newer and the Metal toolchain. Wine/FEX/DXMT setup also uses Homebrew.

```sh
./build.sh
```

`dist/Goose HUB latest.app` contains the launcher and installer, with no engines or MetalGoose implementation bundled.

## Install components

Each component has its own **Install**, **Check for updates**, **Cancel** and **Retry** controls. Install Wine before DXMT; FEX and MetalGoose can be installed independently. The library opens after all four components pass verification. Percentages follow Git transfer counts, completed build tasks and file verification.

Setup resolves the current public branch configured in `Resources/engine-lock.json`, then fetches and builds that exact commit without GitHub authentication. **Check for updates** compares it with the installed commit and returns without compiling when nothing changed. DXMT also rebuilds when its Wine build dependency changes. Sources live in `~/Downloads/Github`. Existing local edits are preserved; commit them before retrying setup. Compiler tools and build outputs live in `~/Library/Caches/GooseHUB`, outside the source repositories.

MetalGoose's `Service/build.py` builds a headless service from the same engine sources as its standalone GUI. GooseHUB fetches that repository directly; it does not copy or launch the GUI app.

Each installation updates only its component in `Contents/Resources/Engines`, records commits and checksums, and re-signs the app. A failed installation restores the previous runtime. The app must be in a writable location. Rebuilding the launcher creates a fresh installer app.

Windows programs and bottle settings remain in `~/Library/Application Support/GooseHUB`.

## Launcher updates

The sidebar gear menu has **About** and **Check for Updates**, using MetalGoose's update flow. Launcher updates come from the latest GitHub release as a signed ZIP without engines. The updater verifies the download checksum when supplied, preserves locally built engines, replaces the launcher and relaunches it. Component updates use their repository branches separately.

The update views and release ordering are adapted from MetalGoose under GPL-3.0.

## Validation

```sh
xcrun swift test --scratch-path "$HOME/Library/Caches/GooseHUB/GooseHUB/swift"
python3 -m unittest discover -s Tests -p 'test_*.py'
```

Developer builds can use `scripts/install-engines.py --component wine --app /path/to/GooseHUB.app` (components: `wine`, `fex`, `dxmt`, `metalgoose`). `--local-sources` skips fetching for working-tree testing; normal setup resolves the latest public branch commit. `--update` skips rebuilding a current component. The installed manifest records the exact source and dependency commits.

The Adrenalin forks remain authoritative. MSync, x87, OpenGL, Direct3D, installer and HID changes are retained. See `ENGINE-POLICY.md`, component licenses and `Resources/engine-sources.json` for provenance and earlier validation.
