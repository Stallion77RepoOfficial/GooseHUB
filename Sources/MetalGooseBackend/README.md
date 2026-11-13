# MetalGoose backend for Goose HUB Adrenalin Edition

This is MetalGoose 1.2.4 from the local MetalGoose checkout (base commit
`d817c4a0c00bf2bb48869bdd7905d951609883db`, including uncommitted engine changes through
19 October 2026). The original source is from <https://github.com/Stallion77RepoOfficial/MetalGoose>.
It is distributed under GPL-3.0; the complete license is in `LICENSE`. Keep this notice and the
license with packaged binaries and provide their corresponding source when distributing.

All of MetalGoose is here except its window: the Metal 4.1/MetalFX/VideoToolbox engine,
capture, frame scheduling, pointer mapping, the non-activating overlay that presents the output
video, the HUD, the ⌘⇧T and ⌘⇧C shortcuts, its settings (`CaptureSettings`) and its Clear Metal
Cache action. `BackendSession` is MetalGoose's `ScalingController` with the hub in place of the
window: the hub names the game to scale instead of a countdown taking the frontmost app, and errors
go back to the hub instead of into an alert. The updater is left out; it replaces the MetalGoose
app, and this backend ships with Goose HUB.

## Build and package

Requires Apple Silicon, macOS 27, Xcode 27/macOS 27 SDK, Swift 6.4 and the Metal toolchain.
From the GooseHUB directory:

```sh
./build.sh
.build/metalgoose/metalgoose-backend --status --json
```

`build.sh` builds `metalgoose-backend` and `default.metallib` into `.build/metalgoose` and copies
both into the app's `Contents/Resources/Engines/MetalGoose/bin`. The backend finds the library
beside the executable, at `../Resources/default.metallib`, or in the enclosing app's
`Contents/Resources/MetalGoose/default.metallib`. An explicit absolute `GOOSE_METALGOOSE_LIBRARY`
environment value can select another readable library. Sign the helper and the app around it
consistently, so macOS attributes the privacy permissions to the same app.

`--status` checks the device, the shader location and the current Screen Recording and
Accessibility grants. It never requests permission, initializes the engine, opens an overlay or
starts capture.

## JSON line control protocol

Launch `metalgoose-backend --serve` with an open stdin pipe. Stdout carries JSON objects
separated by newlines; stderr is for framework diagnostics. The first event is `ready`. Request
IDs are optional strings, echoed in replies, and requests run in the order received. EOF, SIGINT,
SIGTERM and `quit` stop capture, destroy the overlay and restore the pointer before exiting. The
backend builds the Neural Engine's models when it starts, as MetalGoose does at launch.

```json
{"id":"1","command":"status"}
{"id":"2","command":"start","pid":12345,"windowID":678,"configuration":{"frameGenMode":"MGFG-1","frameGenMultiplier":2}}
{"id":"3","command":"configure","configuration":{"scalingMethod":"MGUP-1","scaleFactor":"Fullscreen","renderScale":"67%"}}
{"id":"4","command":"stop"}
{"id":"5","command":"request-permissions","screenRecording":true,"accessibility":true}
{"id":"6","command":"clear-metal-cache"}
{"id":"7","command":"quit"}
```

`start` needs the game's `pid`; a `windowID` must be one of that process's on-screen windows, and
without one the process's topmost ordinary window is taken, as MetalGoose takes it. Both Screen
Recording and Accessibility permission are required, as for MetalGoose's Start Scaling. A
configuration given to `start` or `configure` replaces MetalGoose's settings; each omitted field
takes MetalGoose's default. Triple buffering is fixed while a session runs.

| Key | Default | Accepted values |
| --- | --- | --- |
| `scalingMethod` | Off | Off, MGUP-1 |
| `scaleFactor` | 1.0x | 1.0x, 1.5x, 2.0x, 2.5x, 3.0x, 4.0x, 5.0x, 6.0x, 8.0x, 10.0x, Fullscreen |
| `renderScale` | Native (100%) | Native (100%), 75%, 67%, 50%, 33% |
| `sharpening` | Ultra | Performance (Light), Balanced, Ultra (Strong) |
| `frameGenMode` | Off | Off, MGFG-1 |
| `frameGenMultiplier` | 2 | the highest of 2 and 4 the value reaches |
| `aaMode` | Off | Off, FXAA, SMAA |
| `alignPointer` | true | boolean |
| `showMGHUD` | true | boolean |
| `vsync` | true | boolean |
| `vrr` | false | boolean; effective VRR requires a capable panel |
| `tripleBuffering` | true | boolean |

Replies have `protocolVersion: 2`, `ok`, optional `id`, `event`, `reason`, `status`, `message`
and `error: {code,message}`. A running session sends `stats` each second. A session that ends on
its own sends `stopped` with a `reason`: `shortcut` (⌘⇧T), `capture` (the window or the stream
went away), `fullscreen` or `target-exited`. ⌘⇧T on an idle backend starts a session on the
frontmost app and sends `started` with reason `shortcut`.

Status includes the permission flags, shader path, device, phase, PID and window ID, the current
configuration and metrics. Metrics include capture, output and generated FPS, latency in
milliseconds, the GPU budget estimate, process memory and CPU, and cumulative presented, generated
and dropped counts. `gpuBudgetPercent` is completed GPU command time divided by wall time, not GPU
hardware utilization. End-to-end latency begins at the captured compositor timestamp, not
physical input. The requested multiplier is a preference; `activeMultiplier`, `generationEngine`,
`generationUnavailable` and the output FPS in metrics show what is running.

macOS native fullscreen Spaces cannot host the overlay; the session stops and reports MetalGoose's
error after three checks. Run the game windowed or borderless. Frame generation uses captured color
frames, does not integrate game motion vectors or depth, and adds interpolation latency.

## Local integration changes

- A JSON-lines service and the hub's target replace MetalGoose's window and countdown.
- Shader loading supports subprocess and enclosing Goose HUB resource locations.
- Capture binds the window to its owning process when the stream starts.
- Status reports why presentation is suspended and the engine's generation choice.

The extraction left the upstream checkout unchanged. The build script does not capture, prompt
for privacy access, run a target or install an app.
