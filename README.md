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

Each component has its own **Install**, **Cancel** and **Retry** controls. Install Wine before DXMT; FEX and MetalGoose can be installed independently. The library opens after all four components pass verification. Percentages follow Git transfer counts, completed build tasks and file verification.

Setup fetches the exact public commits in `Resources/engine-lock.json` without GitHub authentication. Sources live in `~/Downloads/Github`. Existing local edits are preserved; commit them before retrying setup. Compiler tools and build outputs live in `~/Library/Caches/GooseHUB`, outside the source repositories.

MetalGoose's `Service/build.py` builds a headless service from the same engine sources as its standalone GUI. GooseHUB fetches that repository directly; it does not copy or launch the GUI app.

Each installation updates only its component in `Contents/Resources/Engines`, records commits and checksums, and re-signs the app. A failed installation restores the previous runtime. The app must be in a writable location. Rebuilding the launcher creates a fresh installer app.

Windows programs and bottle settings remain in `~/Library/Application Support/GooseHUB`.

## Validation

```sh
xcrun swift test --scratch-path "$HOME/Library/Caches/GooseHUB/GooseHUB/swift"
python3 -m unittest discover -s Tests -p 'test_*.py'
```

Developer builds can use `scripts/install-engines.py --component wine --app /path/to/GooseHUB.app` (components: `wine`, `fex`, `dxmt`, `metalgoose`). `--local-sources` skips fetching for working-tree testing; normal setup always fetches the pinned public commits.

The Adrenalin forks remain authoritative. MSync, x87, OpenGL, Direct3D, installer and HID changes are retained. See `ENGINE-POLICY.md`, component licenses and `Resources/engine-sources.json` for provenance and earlier validation.
