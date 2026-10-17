# ThermalWatch — design

Date: 2026-10-17
Status: approved in conversation, awaiting written-spec review

## Purpose

A menu-bar app that shows when Sammy's 14-inch MacBook Pro (Apple M5 Max, Mac17,7, macOS 27) is being thermally throttled. Three uses drive the design:

1. **Local AI slowdowns.** See whether heat is slowing local models served by oMLX (KonaClaw's engine on 127.0.0.1:8901) during long chats or image/video generation.
2. **Always-on glance.** Notice the moment the chip starts throttling while working.
3. **Learn the 14-inch limits.** Find out how long sustained load lasts before the chassis throttles, and by how much.

Success: at any moment the menu-bar icon answers "am I throttled right now?", and the window answers "when was I throttled, how badly, for how long, and what did it cost my token speed?"

## Constraints

- Standalone app in its own git repo at `~/Desktop/claudeCode/ThermalWatch`. Not part of SammyClaw/KonaClaw; it must work whether or not KonaClaw is running.
- No admin rights at runtime. `powermetrics` (needs sudo) is not used.
- Native arm64 only. Build commands run under `arch -arm64`; never Rosetta.
- Personal use. Uses private APIs, so no App Sandbox and no App Store.
- Signed with the existing self-signed "KonaClaw Dev" certificate so the notification permission survives rebuilds.
- Never logs, stores or displays the oMLX API key.
- Never unloads, pauses or otherwise controls oMLX. Read-only polling.
- Minimum OS: macOS 27. Swift 6, SwiftUI, Swift Charts.

## Hardware facts (probed 2026-10-17)

- CPU core layout: `hw.perflevel0` = "Super", 6 cores; `hw.perflevel1` = "Performance", 12 cores. No efficiency cores. The app graphs two CPU clusters (Super, Performance) plus the GPU.
- `notifyutil -g com.apple.system.thermalpressurelevel` → `0` at idle (readable without sudo).
- `pmset -g therm` reports nothing useful on this machine ("No thermal warning level has been recorded").
- `/usr/lib/libIOReport.dylib` loads via `dlopen` (it lives in the dyld shared cache, not on disk). Channel counts: "CPU Stats" 130, "GPU Stats" 140, "Energy Model" 364.
- IOReport cluster channels (group "CPU Stats", subgroup "CPU Complex Performance States"): `PCPU` = the 6 Super cores; `MCPU0` and `MCPU1` = two clusters of 6 Performance cores. Their states are `DOWN`, `IDLE`, then `V<n>P<m>`, where `n` indexes the frequency table. Per-core channels (subgroup "CPU Core Performance States"): `PCPU0`–`PCPU5`, `MCPU00`–`MCPU05`, `MCPU10`–`MCPU15`, with the same state names.
- GPU (group "GPU Stats"): subgroup "GPU Performance States", channel `GPUPH`, states `OFF`, `P1`–`P15`. Subgroup "CLTM-induced GPU Performance States", channel `GPU_CLTM`, states `OFF`, `P1`–`P15`, `NO_CLTM`. Any residency outside `NO_CLTM` means the GPU is being held down by closed-loop thermal management, which is a direct throttle signal.
- Frequency tables (pmgr `voltage-states*-sram`, values in **kHz** on M5): Super (`PCPU`) = `voltage-states5-sram`, 20 entries, 1,308,000–4,608,000. Performance (`MCPU0`/`MCPU1`) = `voltage-states22-sram` / `voltage-states23-sram`, 15 entries, 1,344,000–4,380,000. GPU = `voltage-states9` (non-sram), 14 entries in **MHz** with entry 0 = 0, top = 1620.
- Energy: "Energy Model" channel `GPU Energy` (unit nJ) works. `CPU Energy` reads 0 on M5, so CPU power comes from the SMC.
- SMC (`AppleSMC` service, user client selector 2, 80-byte key struct) works without sudo. `FNum` = 2 fans; `F0Ac`/`F1Ac` = current RPM (0 at idle); `F0Mx` = 7826. `PHPC` = CPU power (5 W idle → 26 W with all cores busy). `PSTR` = whole-system power. 320 `T*` temperature keys; CPU die sensors are `Tp*` (Super) and `Tm*` (Performance), GPU die sensors are `Tg*`.
- oMLX's admin API answers 200 on localhost **without a key** (KonaClaw sets `skip_api_key_verification` on loopback). `/admin/api/stats` counters (`total_completion_tokens`) only change when a request **finishes**, so they cannot give a live rate. `/admin/api/activity` returns `active_models.total_active_requests` and `active_models.models[].generating[]`, where each entry has `request_id`, `generated_tokens` (live, rising during generation) and `elapsed_seconds`.

## Architecture

A single SwiftUI app (`LSUIElement`, menu bar only, no Dock icon) built with SwiftPM. A `build.sh` wraps the executable into `ThermalWatch.app`, embeds `Info.plist`, and signs it with "KonaClaw Dev". Launch at login via `SMAppService.mainApp`.

### Units

Each unit has one job and is tested on its own. Sources sit behind a `Source` protocol so tests can substitute fakes.

| Unit | Responsibility | Data source |
|---|---|---|
| `PressureSource` | Thermal pressure level: nominal(0) / moderate(1) / heavy(2) / trapping(3) / sleeping(4) | `notify_register_check` + `notify_get_state` on `com.apple.system.thermalpressurelevel` |
| `ClockSource` | Per-cluster (Super, Performance, GPU) average active frequency in MHz, busy %, GPU thermal cap flag, and GPU power in watts | IOReport subscriptions to "CPU Stats", "GPU Stats", "Energy Model"; frequency tables from pmgr `voltage-states` |
| `SMCSource` | Hottest CPU die temperature (`Tp*`, `Tm*`), hottest GPU die temperature (`Tg*`), fan RPM (`F<n>Ac`), CPU power (`PHPC`), system power (`PSTR`) | AppleSMC user client |
| `TokenSource` | oMLX generation tokens/sec for the last interval, and whether a request is active; `nil` when idle or unreachable | `GET http://127.0.0.1:8901/admin/api/activity`; adds `Authorization: Bearer <key>` only if a key is configured |
| `Sampler` | Once per second, reads every source and assembles one `Sample` | the sources |
| `ThrottleDetector` | Pure function: sample window → `ThrottleState` | samples |
| `HistoryStore` | SQLite persistence, 7-day retention, range queries, event list, CSV export | samples |
| `AlertCenter` | Rate-limited macOS notifications | throttle states |
| `LoadTest` | Generates CPU/GPU load, records a run, produces a result | Metal, threads, samples |
| `thermalwatch-probe` | CLI that prints one reading from each source | the sources |

### The `Sample` record

```
timestamp            Double   (Unix seconds)
pressure             Int?     (0–4)
superMHz, perfMHz, gpuMHz        Double?
superBusy, perfBusy, gpuBusy     Double?   (0–1)
gpuThermalCapped     Bool?     (GPU_CLTM residency outside NO_CLTM)
cpuWatts, gpuWatts, systemWatts  Double?
cpuTempC, gpuTempC   Double?
fanRPM               [Double]  (empty if unavailable)
tokensPerSec         Double?
state                Int       (0 cool, 1 warm, 2 throttled)
clockLimited         Bool
```

Every field from a source is optional; a failed source yields `nil` and never blocks the others.

### Token speed

The app polls `/admin/api/activity` once per second and remembers each generating request's `generated_tokens` by `request_id`. For each poll:

- For a request seen in the previous poll: its contribution is `max(0, tokens_now − tokens_before)`.
- For a request not seen before: its contribution is `generated_tokens` if its `elapsed_seconds` is no more than the time since the previous poll, otherwise 0 (it started before the app was watching).
- `tokensPerSec = sum of contributions / seconds since the previous poll`.
- `nil` when no request is generating, when the request fails, or on the first poll.

No key is needed by default (see Hardware facts). If oMLX ever answers 401, Settings offers an optional key source: an env file path (default `~/.konaclaw.env`) and a variable name. Parsing follows the shell `KEY=value` form; values are taken whole, so a `#` inside a value is not treated as a comment. The response also contains `api_key`; the app decodes only the fields it needs and never logs the response body.

"oMLX is generating" (used by the load-test warning) means `active_models.total_active_requests > 0`.

### Throttle rule

`ThrottleDetector` returns `throttled`, `warm` or `cool`, plus `clockLimited`:

- **Clock-limited**: some cluster has been more than 60% busy for at least 5 consecutive seconds, and its frequency is more than 15% below that cluster's **reference peak**.
  - The reference peak is the highest frequency seen for that cluster at more than 60% busy in the last 7 days of history.
  - With no such history, the reference peak is the maximum of the cluster's pmgr frequency table.
- **GPU thermal cap**: `gpuThermalCapped` is true. This also counts as clock-limited.
- **Throttled**: pressure ≥ moderate (1), or clock-limited.
- **Warm**: not throttled, and either a die temperature is above 95 °C or a busy cluster's frequency is 5–15% below its reference peak.
- **Cool**: otherwise.

Thresholds (60%, 5 s, 15%, 5%, 95 °C) are constants in one place.

### Throttle events

An event is a run of consecutive throttled samples, closed after 10 seconds without throttling. Each event records start, end, duration, worst pressure level, the largest clock drop (percent of reference peak), and mean tokens/sec in the 60 seconds before the event versus during it (when token data exists for both).

## Interface

### Menu-bar icon

A chip SF Symbol with a colored dot:

- green: cool
- yellow: warm, or pressure moderate
- orange: pressure heavy, or clock-limited at nominal/moderate pressure
- red: pressure trapping or sleeping

A slash over the dot means `clockLimited` right now. The colors live in one palette. Optional: show the hottest die temperature next to the icon (Settings, off by default).

### Popover

```
┌──────────────────────────────────────────┐
│ ● COOL            Pressure: Nominal      │
│ Super   4.42 GHz  ██████████░  97% of max │
│ Perf    3.91 GHz  █████████░░  91%        │
│ GPU     1.62 GHz  ██████░░░░░  64%        │
│ CPU 78°  GPU 71°  Fans 2,400 rpm  42 W    │
│ oMLX    38 tok/s                          │
│ ─ last 10 min ──────────────────────────  │
│ [sparkline: Perf clock, pressure band]    │
│ Throttled 0s today · longest 0s           │
│ [Open window]  [Load test]  [Settings]    │
└──────────────────────────────────────────┘
```

Unavailable values show "—".

### Window

- Range picker: 10 min / 1 h / 6 h / 24 h / 7 d, and a scrubber to move back through history.
- Four stacked Swift Charts on a shared time axis:
  1. Clocks: Super, Performance, GPU as % of reference peak.
  2. Temperatures: CPU and GPU die °C; fan RPM on a second axis.
  3. Power: CPU and GPU watts.
  4. oMLX tokens/sec.
- A band behind all four charts shades throttled stretches by pressure level (yellow/orange/red), hatched where `clockLimited`.
- Throttle events list: start, duration, worst level, clock drop, tokens/sec before → during (e.g. "41 → 29 tok/s, −29%"). Clicking an event moves the charts to it.
- Export the visible range to CSV.
- A source that is unavailable shows a note on its chart ("Clock data unavailable").

Ranges longer than 1 hour are downsampled for drawing (min/max per bucket), so the 7-day view stays fast.

### Alerts

macOS notifications via `UNUserNotificationCenter`:

- Pressure reaches heavy (2) or higher.
- `clockLimited` continuously for 30 seconds or more.

At most one alert per 10 minutes overall. Each alert type has its own switch in Settings.

### Load test

Opened from the popover.

- Choose **CPU**, **GPU** or **both**, and a duration of 5, 10 or 20 minutes.
- **CPU load**: one thread per logical core (18) running a dependent floating-point loop the optimizer cannot remove. No disk I/O, under 50 MB memory.
- **GPU load**: a Metal compute kernel running fused multiply-add over a 64 MB buffer, dispatched repeatedly with a short wait between command buffers so the UI stays responsive.
- During the run the same four charts update live.
- Stops within about 1 second on: the Stop button, app quit, the duration timer, or any die temperature above 105 °C.
- Before starting, if oMLX is serving a request (`total_active_requests > 0`), the app warns: "Kona is generating — results will be skewed and the reply will slow down", and requires confirmation.
- Result card: seconds until first throttle (or "did not throttle"), steady-state clock drop per cluster (mean of the last 60 s vs reference peak), peak temperatures, watts at start (first 30 s mean) vs end (last 30 s mean), and the stop reason.
- Results are saved in the database with an optional note (e.g. "desk", "cooling stand", "Low Power mode") and listed for side-by-side comparison.

### Settings

- Launch at login (default on)
- Icon temperature label (default off)
- Alert switches (both default on)
- History retention (default 7 days)
- oMLX URL (default `http://127.0.0.1:8901`) and API key source: env file path (default `~/.konaclaw.env`) and variable name

## Storage

SQLite at `~/Library/Application Support/ThermalWatch/history.sqlite`, through the system `SQLite3` library (no third-party dependency). Tables: `samples`, `events`, `load_tests`. Pruning runs at launch and hourly. Expected size: about 86,400 rows/day, roughly 10 MB for 7 days. Writes are batched every 10 seconds.

## Error handling

- Each source is wrapped: an exception or bad read yields `nil` for that field and a per-source "unavailable" flag, which the UI displays. The sampler never stops because of one source.
- If IOReport cannot be loaded or subscribed, clocks and power are unavailable; pressure, temperatures, fans and tokens still work.
- If no `Tp*`/`Tm*`/`Tg*` SMC keys exist (a different Mac), `SMCSource` reports temperatures as unavailable rather than guessing. SMC readings outside 0–130 °C are ignored as bogus.
- oMLX unreachable or 401: `tokensPerSec` is `nil`; Settings shows the last error (without the key).
- SQLite write failure: samples stay in memory (last 1 hour) and a banner shows the error.

## Testing

- **Unit tests (`swift test`)**, no hardware needed:
  - `ThrottleDetector`: scripted sample sequences covering the 60%-for-5-s condition, the 15% drop, the warm band, pressure-only throttling, and the table-max fallback with empty history.
  - Token math: normal deltas, idle polls, oMLX restart (counters go backwards), failed requests.
  - Env-file parsing, including a value containing `#`.
  - Event building (10-second close rule, before/during tokens/sec).
  - History pruning at the retention boundary, downsampling, CSV export.
  - Alert rate limiting.
  - Load-test stop conditions with a fake clock and fake temperature source.
- **Hardware probe (`thermalwatch-probe`)**: prints one reading from each source and whether it looks plausible (pressure 0–4, clocks within the table range, temperatures 20–110 °C). Informational, not a build gate.
- **Manual check**: a 5-minute CPU+GPU load test; the icon changes color and a throttle event is recorded.

## Build order

1. Probe CLI and the source units.
2. Sampler, throttle detector, history store.
3. Menu-bar icon and popover.
4. Window with charts and the events list.
5. Token source.
6. Alerts.
7. Load test.
8. Settings, launch at login, packaging and signing.

## Out of scope (v1)

- Remote or phone view
- KonaClaw dashboard integration
- Per-process CPU blame
- Fan control (needs root)
- Intel Macs and other Apple Silicon models (may work, not tested)
