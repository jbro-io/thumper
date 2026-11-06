# Thumper

A native macOS menu-bar utility for watching processes in a movable desktop overlay. Track every matching process with a regular expression, such as `WindowServer|mentat|codex`.

## Run

Open **build/Thumper.app**, then click the waveform icon in your menu bar.

The picker opens beside the overlay on the same monitor. Before an overlay exists, it opens in the center of that monitor. It is not attached to the menu-bar icon.

1. Enter a process-name expression and click **Apply**. Matching ignores case. Every matching instance is tracked, including instances that start later.
2. Click **Done** or outside the picker to dismiss it.
3. Drag the unlocked overlay by its text to position it.
4. Open **Settings** to choose a monitor, enable **Always in front**, change the text size/color, or lock the overlay so clicks pass through it.

The picker uses native Liquid Glass on macOS 26. The overlay has a faint background (18% opacity by default) for readability, with no border or title bar. **Settings → Overlay background** offers Subtle with adjustable opacity, Text only for full transparency, or Liquid Glass. Earlier macOS versions use the system material fallback.

Click an overlay column heading to sort by it; click again to reverse the order. CPU/GPU/Memory/Threads/Ports start with the largest value first. The active heading shows an arrow. Sorting is live and saved between launches. When click-through is locked, use **Settings → Overlay sort** instead.

The overlay’s Process column automatically fits the widest tracked name, with room for its heading and sort arrow. It grows or shrinks as matching processes change and follows the selected text size.

Resizing keeps the nearest screen edges fixed: near the right edge it grows left, near the left edge it grows right, near the bottom it grows upward, and near the top it grows downward. Dragging the overlay chooses new anchor edges. The placement is saved across restarts and stays within the selected monitor.

Click a process row to highlight it. Only one row is highlighted at a time, and the highlight follows that process as sorting changes. Clicking a row never modifies the regex filter.

Right-click anywhere on the overlay to edit the regex directly in its menu, then press **Apply** or Return. The menu also offers **Unlock Overlay** when click-through is enabled, plus the full process list, Hide Overlay, and **Quit Thumper**. Locked left-clicks pass through the process table; right-click remains available. Escape or clicking outside dismisses the menu without applying a draft. Invalid expressions leave the active filter unchanged.

Right-click the menu-bar icon for quick access to the picker, Always in Front, overlay visibility, click-through, and Quit.

To quit, use **Quit Thumper** in the overlay’s right-click menu or at the bottom of the process picker. **⌘Q** also quits while Thumper’s controls are active.

## Filters

| Expression | Tracks |
| --- | --- |
| `WindowServer\|mentat\|codex` | All instances with any of these names, including names with prefixes/suffixes |
| `^(WindowServer\|mentat\|codex)$` | Only exact names |
| `chrome.*helper` | Chrome helper processes |
| `^(?!.*helper).*codex` | Codex processes whose names do not contain “helper” |

The filter is saved across app and Mac restarts. Exited processes disappear; matching replacements appear with their new PIDs. An invalid expression leaves the last applied filter active. Empty expressions track nothing. The separate search field filters the picker list without changing the overlay.

## Metrics

- **CPU %** uses sampled CPU time. 100% is one fully occupied core; multithreaded processes can exceed 100%. Mach clock ticks are converted with the machine’s timebase, including on Apple silicon.
- **GPU %** uses GPU-driver `AppUsage` / `accumulatedGPUTime` counters from IORegistry. Deltas are calculated per GPU client, then combined per process. New clients, changed queue counts, counter resets, and reused PIDs establish fresh baselines. No root helper is needed. These driver properties are not a stable Apple API, so availability can vary by macOS version and driver. A dash means no reliable counter/baseline; a measured zero means idle.
- **Memory** appears immediately after GPU % in the overlay and process picker. It reports the process’s physical memory footprint, matching the meaning of Activity Monitor’s Memory column, with decimal KB/MB/GB units. Sorting compares the byte counts. It is visible by default and can be hidden under **Settings → Visible Metrics**. Missing readings display a dash.
- **Threads** is the process thread count.
- **Ports** is the Mach-port count, matching the meaning in Activity Monitor. These are not TCP/UDP port numbers.
- **PID** is the current process ID. PID plus start time prevents attaching old readings to a recycled PID.

CPU, GPU, memory, and normal thread counters refresh at the selected interval (0.5–5 seconds). Memory uses the native `proc_pid_rusage` physical-footprint counter. Mach ports and protected-process CPU/thread/memory fallbacks use Apple’s signed `/usr/bin/top` observer about every 5 seconds. Its first CPU sample is discarded. Everything stays on the Mac; the app has no network service or telemetry.

The GPU approach is also documented in [Stats’ per-process GPU implementation discussion](https://github.com/exelban/stats/issues/3710). The glass material uses Apple’s [NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview).

## Build and check

Requires macOS 13+ and an Xcode toolchain that includes the macOS 26 SDK. There are no package dependencies.

```sh
./scripts/build.sh                 # Release app, signed locally
./scripts/release.sh               # Release app plus ZIP and SHA-256 checksum
./scripts/run.sh                   # Build and open
swift test --disable-sandbox       # Counter, GPU lifecycle, regex, parser, geometry tests
build/Thumper.app/Contents/MacOS/Thumper --diagnose
```

Diagnostics sample live processes, verify CPU against POSIX resource timing, read Mach ports and protected-process counters, and report live per-process GPU readings. Run outside a restricted automation sandbox so macOS permits reading other processes. The app is signed for local use; distributing it to other Macs would additionally require a Developer ID signature and notarization.

Open `Package.swift` in Xcode to work on the project. `Sources/Thumper` contains the native interface and overlay, `Sources/ThumperCore` contains sampling and matching, and `Sources/CProcessMetrics` provides the small Darwin process bridge.
