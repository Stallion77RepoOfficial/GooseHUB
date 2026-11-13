# D3D12 validation, 2026-11-08

The local fork remains authoritative. Replacing the 13 incremental source files with the pre-task snapshots reconstructs the complete delivered 0.2.8 source digest exactly: `802cd7cb1a46553ef6dc8245a063d91fe6df53f2ca29f2b2f950fe2d11484e45`. The resulting source digest is `b0c464ca38960d1a3721f0dfddd2e02ac3910d8a412a5b50536843d8fe11fa20`. Wine source and the delivered D3D9/OpenGL changes were retained.

The D3D12 bridge now executes DXBC geometry stages, shares placed storage with the D3D11 encoder, tracks whole-resource copies, retains descriptor views and heaps, filters unused compute UAVs, preserves live GPU-address aliases, and honors UAV/aliasing barriers on the GPU. A failed native fence allocation returns failure rather than a CPU-only success object. Command lists close their encoders individually and commit once per ExecuteCommandLists batch, including immutable recordings queued behind future fences. The native shader converter lowers shared-memory constant expressions before typed IR conversion. Bundled media loading removes build-machine library search paths so GStreamer and its plugins use the same registry.

Query results use their actual completed GPU values. A device worker waits for the producer submission, publishes the results into shared storage, and releases a GPU wait before the result copy. The submission thread can continue recording. D3D11's private wait export keeps atomic wait/notification inside the same runtime module. Query snapshots survive index reuse and repeated resolves. This path is the default; DXMT_D3D12_ASYNC_QUERY_RESOLVE=0 selects the synchronous fallback.

D3D12 also waits for a valid graphics pipeline to finish compiling instead of skipping its first draw. It identifies the bridge through the existing D3D11On12 association. Ordinary D3D11 keeps its existing asynchronous-compilation policy. The cold single-draw test produced only the blue clear before this correction and the expected red pixel afterward, with the global asynchronous policy enabled and its wait budget set to zero.

Validation completed:

- 22 modes on ARM64EC, x64 and x86: 66 successful runs, with default query resolution, normal compiler discovery and zero pipeline wait budget.
- Three synchronous-fallback modes per architecture: nine successful runs.
- D3D11 geometry and D3D9 constant regressions on all three architectures: six successful runs.
- Packaged Wine/DXMT engines: six additional targeted modes per architecture, 18 successful runs.
- All 14 Swift tests passed.

The matrix checks real GPU pixels, buffer contents, timestamps, visible/empty occlusion results, preserved sentinel bytes, overlapping UAV descriptors, aliasing, resource retirement, geometry/depth/MRT copies, and command lists reset before a waiting multi-list batch executes. Legacy logs and native-code hashes are included. Shader files here are generated validation inputs; no game shader bytecode, GPU captures, environment snapshots or desktop images are included.

Severed Steel was tested with normal skin cache and occlusion settings. The user confirmed complete models after the GPU barrier correction. A diagnostic CPU completion wait also restored models but reduced performance to 10–20 FPS; that wait is not enabled. The user reported roughly 100 FPS in the D3D11 control and substantially improved D3D12 fluidity in a later run. That run's last 300 presents had a median interval of 16.03 ms. These moving-scene samples are not a matched FPS benchmark or a claim of D3D11 parity. The isolated query fixture's three interleaved comparisons measured median CPU submission time changing from 35.74 ms to 1.77 ms; those numbers are not game FPS.

The final packaged runtime completed more than 13,000 successful presents without device loss, fatal exceptions or skipped pipeline draws. Its recent uncontrolled sample had a median present interval of 37.99 ms; visual confirmation of that exact package was not received before this record. The variation between runs is unresolved, so no stable FPS target is claimed.

D3D12 remains experimental. Complete API coverage and performance parity across games are not claimed. The optional frame CSV includes queue/readback/binding timings for further investigation. Capture and diagnostic synchronization overrides are disabled in the release environment.

To rebuild the compatibility executable, use a MinGW C++20 compiler and link d3d12, dxgi, d3dcompiler, dxguid, uuid, gdi32, user32 and ole32. Run it from the shaders directory in an isolated Wine prefix with the matching DXMT DLLs. Modes and assertions are in d3d12-compat-validation.cpp. The --dxbc-placed-cold-single mode includes two warm-up passes followed by exactly one draw using a fresh vertex shader.
