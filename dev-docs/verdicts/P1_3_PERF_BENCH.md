# P1.3 Stream 1 Deliverable B — TCL bridge perf bench

## Methodology

- N=5 warm runs per file; first run discarded (cold cache); stats computed over remaining 4.
- File selection: bluice corpus (5 repos), stratified by LoC
  (small <500 / medium 500-2000 / large >2000); ~12 files per bucket.
- Two timings per file:
  - **Parse-only**: tclsh + bridge subprocess wall-clock; no Python overhead.
  - **End-to-end**: full `_parse_tcl_native` (subprocess + json.loads + Symbol construction).
- Old bridge materialised from `tcl-native-parser` branch (mirrors dual-validate cache).

## Two-number policy

- Parse-only ratio (new/old) ≤ 1.5x → genuine parsing-logic regression test.
- End-to-end ratio  (new/old) ≤ 2.0x → permits subprocess overhead allowance.

## Bucket: small  (n=12)

| File | LoC | new parse-only median (s) | old parse-only median (s) | parse ratio | new end-to-end median (s) | old end-to-end median (s) | e2e ratio |
|------|-----|---------------------------:|---------------------------:|------------:|---------------------------:|---------------------------:|----------:|
| `BluIceWidgets/Admin.tcl` | 112 | 0.050 | 0.040 | 1.23x | 0.048 | 0.038 | 1.24x |
| `BluIceWidgets/pkgIndex.tcl` | 114 | 0.343 | 0.093 | 3.68x | 0.338 | 0.089 | 3.80x |
| `DcsWidgets/UserAlignBeamStatus.tcl` | 127 | 0.051 | 0.039 | 1.28x | 0.053 | 0.042 | 1.27x |
| `dcss/scripts/devices/beam_size_sample_x_dummy.tcl` | 35 | 0.040 | 0.022 | 1.77x | 0.042 | 0.025 | 1.69x |
| `dcss/scripts/devices/mirror_vert_chin_bl11.tcl` | 76 | 0.044 | 0.034 | 1.28x | 0.048 | 0.038 | 1.25x |
| `dcss/scripts/devices/undulator_monitor.tcl` | 205 | 0.098 | 0.130 | 0.75x | 0.092 | 0.125 | 0.74x |
| `dcss/scripts/operations/checkGapOwnership.tcl` | 11 | 0.031 | 0.015 | 2.02x | 0.030 | 0.015 | 2.06x |
| `dcss/scripts/operations/gapHarmonic.tcl` | 7 | 0.030 | 0.012 | 2.50x | 0.030 | 0.012 | 2.52x |
| `dcss/scripts/operations/optimizeTable.tcl` | 174 | 0.150 | 0.099 | 1.51x | 0.144 | 0.094 | 1.54x |
| `dcss/scripts/operations/table_vert_1_encoder_op.tcl` | 8 | 0.028 | 0.012 | 2.31x | 0.028 | 0.012 | 2.29x |
| `dhs-tcl/main/scripts/base/devices/DeviceBase.tcl` | 49 | 0.044 | 0.024 | 1.81x | 0.043 | 0.024 | 1.83x |
| `dhs-tcl/main/scripts/galil/devices/GalilInputKeyValueStatus.tcl` | 32 | 0.038 | 0.021 | 1.80x | 0.042 | 0.025 | 1.67x |

**small aggregate**: parse-only ratio median = 1.79x, end-to-end ratio median = 1.68x

## Bucket: medium  (n=12)

| File | LoC | new parse-only median (s) | old parse-only median (s) | parse ratio | new end-to-end median (s) | old end-to-end median (s) | e2e ratio |
|------|-----|---------------------------:|---------------------------:|------------:|---------------------------:|---------------------------:|----------:|
| `BluIceWidgets/Anneal.tcl` | 783 | 0.275 | 0.614 | 0.45x | 0.275 | 0.614 | 0.45x |
| `BluIceWidgets/BluIce.tcl` | 1106 | 0.344 | 0.426 | 0.81x | 0.335 | 0.417 | 0.80x |
| `BluIceWidgets/IonChamberFile.tcl` | 610 | 0.239 | 0.252 | 0.95x | 0.225 | 0.239 | 0.94x |
| `BluIceWidgets/RunSequenceView.tcl` | 700 | 0.249 | 0.301 | 0.83x | 0.250 | 0.301 | 0.83x |
| `BluIceWidgets/bluice.tcl` | 703 | 0.226 | 0.295 | 0.77x | 0.244 | 0.314 | 0.78x |
| `DcsWidgets/DetectorBase.tcl` | 528 | 0.043 | 0.143 | 0.30x | 0.050 | 0.150 | 0.33x |
| `DcsWidgets/Persistent.tcl` | 1058 | 0.356 | 0.658 | 0.54x | 0.355 | 0.658 | 0.54x |
| `dcss/scripts/devices/attenuation.tcl` | 1414 | 1.567 | 0.801 | 1.96x | 1.565 | 0.799 | 1.96x |
| `dcss/scripts/operations/alignFrontEnd.tcl` | 672 | 0.296 | 0.884 | 0.34x | 0.302 | 0.890 | 0.34x |
| `dcss/scripts/operations/collectFrameMARCCD.tcl` | 748 | 0.275 | 0.452 | 0.61x | 0.270 | 0.448 | 0.60x |
| `dcss/scripts/operations/loopFast.tcl` | 1591 | 0.642 | 1.130 | 0.57x | 0.641 | 1.130 | 0.57x |
| `dcss/scripts/operations/runTimer.tcl` | 979 | 0.449 | 1.058 | 0.42x | 0.439 | 1.048 | 0.42x |

**medium aggregate**: parse-only ratio median = 0.59x, end-to-end ratio median = 0.59x

## Bucket: large  (n=12)

| File | LoC | new parse-only median (s) | old parse-only median (s) | parse ratio | new end-to-end median (s) | old end-to-end median (s) | e2e ratio |
|------|-----|---------------------------:|---------------------------:|------------:|---------------------------:|---------------------------:|----------:|
| `BluIceWidgets/CassetteView.tcl` | 4064 | 1.297 | 2.436 | 0.53x | 1.312 | 2.451 | 0.54x |
| `BluIceWidgets/ListSelection.tcl` | 2285 | 0.708 | 1.123 | 0.63x | 0.712 | 1.127 | 0.63x |
| `BluIceWidgets/QueueView.tcl` | 3994 | 1.165 | 2.121 | 0.55x | 1.153 | 2.109 | 0.55x |
| `BluIceWidgets/RobotView.tcl` | 4620 | 1.570 | 3.102 | 0.51x | 1.590 | 3.123 | 0.51x |
| `BluIceWidgets/SequenceActions.tcl` | 2435 | 0.285 | 1.106 | 0.26x | 0.294 | 1.115 | 0.26x |
| `BluIceWidgets/SpectrometerView.tcl` | 2081 | 0.678 | 0.905 | 0.75x | 0.687 | 0.914 | 0.75x |
| `DcsWidgets/Entry.tcl` | 2069 | 0.608 | 0.733 | 0.83x | 0.594 | 0.719 | 0.83x |
| `DcsWidgets/RasterGroupBase.tcl` | 6950 | 2.421 | 3.017 | 0.80x | 2.449 | 3.044 | 0.80x |
| `DcsWidgets/tcltls-1.7.16/tests/tlsIO.test` | 2075 | 0.219 | 0.576 | 0.38x | 0.257 | 0.615 | 0.42x |
| `dcss/scripts/operations/CG.tcl` | 5638 | 2.070 | 7.351 | 0.28x | 2.084 | 7.365 | 0.28x |
| `dcss/scripts/operations/centerCrystal.tcl` | 2898 | 1.013 | 2.032 | 0.50x | 0.989 | 2.008 | 0.49x |
| `dcss/scripts/operations/gridGroupConfig.tcl` | 3883 | 1.482 | 2.299 | 0.64x | 1.463 | 2.279 | 0.64x |

**large aggregate**: parse-only ratio median = 0.54x, end-to-end ratio median = 0.54x

## Overall verdict

- Parse-only ratio (median across all files): **0.76x**  (target ≤ 1.5x → PASS)
- End-to-end ratio (median across all files): **0.77x**  (target ≤ 2.0x → PASS)

- Parse-only p95 ratio: 2.31x
- End-to-end p95 ratio: 2.29x

## Subprocess overhead breakdown

End-to-end > parse-only by `(subprocess fork+exec) + (json.loads) + (Symbol construction)`.
- Median end-to-end - parse-only delta: **0.0 ms** per call.

Two-number verdict:
- If parse-only PASS and end-to-end FAIL: subprocess overhead is the cost; candidate for post-P1.4 subprocess-pooling optimisation.
- If parse-only FAIL: the parsing logic itself regressed; BLOCK P1.3 close.

## Reproducer

```bash
cd /home/giles/git/jcodemunch-mcp-fork
python3 validation/probes/p1_3_perf_bench.py
```