# YORI Core Code

A public selected-code collection for portfolio review of YORI hardware acquisition, BLE transport, and App-side movement evaluation. This is not a complete runnable App or a standalone Swift package.

Inspection date: October 23, 2026.

## Scope and provenance

This collection contains exactly two primary Arduino sketches and eight Swift core files. All ten source files are byte-for-byte copies of the corresponding files in the original project. Existing filenames, identifiers, comments, thresholds, behavior, and protocol definitions are unchanged. New documentation is in English.

The original App and firmware remain in their original locations. The copies here are a snapshot, not another implementation branch that automatically stays synchronized. `SOURCE_MANIFEST.json` records each selected source path and separate original/exported byte counts and SHA-256 digests. These paired hashes are equal: the final text scan found no Chinese text in any selected file, so no comment translation was necessary. It also records the hashes of the original App files used for protocol comparison but deliberately omitted from this selection. All source paths are relative to the original project root; collection paths are relative to this collection root.

The findings below distinguish:

- **Code inspection:** behavior directly visible in the supplied source.
- **Integration concern:** an inference from interacting code paths, requiring runtime verification.
- **Not verified:** compilation, flashing, sensor measurements, BLE delivery, calibration outcomes, scoring accuracy, or voice output on physical devices during this preparation.

No firmware, App, or application backend was run during preparation. Publishing these sources does not establish that they compile or behave correctly on physical devices.

## Included source files

| File | Responsibility |
| --- | --- |
| [Firmware/YORI_Flex/YORI_Flex.ino](Firmware/YORI_Flex/YORI_Flex.ino) | Read three IMUs and two EMG ADC channels; calculate baseline-relative angles; publish binary BLE packets; accept calibration requests. |
| [Firmware/YORI_Smart_Mat/YORI_Smart_Mat.ino](Firmware/YORI_Smart_Mat/YORI_Smart_Mat.ino) | Read four analog pressure channels and publish labeled raw ADC values over BLE and USB serial. |
| [YogaApp/YORILiveSensorModels.swift](YogaApp/YORILiveSensorModels.swift) | Transport-independent Flex and Mat samples, source availability, supported poses, and structured evaluation results. |
| [YogaApp/YORILiveEvaluationManager.swift](YogaApp/YORILiveEvaluationManager.swift) | Observe the original BLE managers, pair Flex samples, control evaluation/scoring lifecycle, and publish live results. |
| [YogaApp/YORIPoseEngine.swift](YogaApp/YORIPoseEngine.swift) | Deterministic Mountain and Cat-Cow evaluation, optional pressure symmetry, and Cat-Cow EMG baseline normalization. |
| [YogaApp/YORISessionEvaluator.swift](YogaApp/YORISessionEvaluator.swift) | Aggregate active-session samples, calculate pose-specific raw scores, select deterministic feedback, and produce a final result. |
| [YogaApp/YORIScoreCalibrator.swift](YogaApp/YORIScoreCalibrator.swift) | Map raw dimensions into displayed training scores using shared prototype interpolation curves. |
| [YogaApp/YORIStartingPositionStabilityDetector.swift](YogaApp/YORIStartingPositionStabilityDetector.swift) | Detect a short low-movement starting window and calculate stable-window EMG medians. |
| [YogaApp/YORIActivePracticeFeedbackPresenter.swift](YogaApp/YORIActivePracticeFeedbackPresenter.swift) | Map structured movement results into display text, including Mountain debounce and combined Cat-Cow issues. |
| [YogaApp/YORIInterventionDecisionEngine.swift](YogaApp/YORIInterventionDecisionEngine.swift) | Decide when a persistent issue is eligible for an automatic coaching intervention, subject to recovery and cooldown rules. |

Each primary `.ino` filename matches its enclosing sketch folder exactly. Development examples inside existing Swift files remain intact and are synthetic examples, not participant data or runtime-validation evidence.

## Hardware acquisition visible in the sketches

### YORI Flex

The sketch identifies its intended platform as ESP32-S3. Exact board variant, Arduino board profile, core version, library version, physical wiring, and flashed-device provenance were not supplied as a build manifest and remain unverified.

The implemented configuration is:

| Item | Source configuration |
| --- | --- |
| I2C | SDA GPIO 4, SCL GPIO 5, clock configured to 400 kHz. |
| Multiplexer | TCA9548A at address `0x70`; `selectChannel()` writes a channel bitmask. |
| IMUs | MPU-6500 register interface at `0x68`, selected through channels 0 / 1 / 2 for T3 / T12 / S1. |
| IMU range configuration | Accelerometer configured for +/-2 g; gyroscope configured for +/-500 degrees/second. |
| EMG ADC | DFR1184 / `DFRobot_ADS1115_I2C` at `0x48`, through multiplexer channel 5; reads ADC channels 1 and 2. |
| Sample scheduling | `SAMPLE_INTERVAL_MS = 50`, targeting 20 Hz outside blocking work. Actual rate is not measured. |
| USB serial | 115200 baud; CSV-style sensor rows plus diagnostic/calibration lines beginning with `#`. |

`readIMU()` reads 14 register bytes, skips temperature, divides accelerometer counts by 16384 and gyro counts by 65.5, and calculates roll/pitch using accelerometer-based `atan2` expressions. No complementary filter, Kalman filter, or gyro-based orientation fusion is implemented in this sketch. Motion-related effects on these angles require physical validation.

`calibrateIMU()` takes 60 attempts per IMU with a 10 ms delay per attempt and computes circular-mean roll/pitch offsets from successful reads. `calibrateAll()` first waits 2000 ms and then calibrates the three IMUs sequentially. Calibration runs at startup and upon a later request. The main loop subtracts each sensor's zero and wraps angles into the implemented (-180, 180] interval.

`readEMG()` treats the ADC library result as millivolts, clamps it to 0...10000, and returns zero when ADC initialization failed. BLE carries rounded integer millivolts; the serial header labels these fields `emg1_mv` and `emg2_mv`. The external library's conversion and the physical EMG front end were not independently verified. These values are not already normalized muscle-activation percentages.

If any IMU read fails, the loop reports an error over serial and skips that sample's normal sensor output. Neither packet format includes a sensor-health flag. Failed ADC initialization therefore cannot be distinguished from a legitimate zero EMG reading using the MAIN packet alone.

### YORI Smart Mat

The sketch uses ESP32 Arduino BLE APIs and sets `analogReadResolution(12)`. It does not specify an exact board model or ADC voltage/attenuation configuration. Confirm that the intended board supports the configured analog pins before building or flashing.

| Logical channel | Configured pin |
| --- | --- |
| LH / left hand | GPIO 0 |
| RH / right hand | GPIO 1 |
| LF / left foot | GPIO 4 |
| RF / right foot | GPIO 3 |

Each loop reads the four channels, assembles a labeled text value, updates the BLE characteristic, notifies when connected, prints the same value over serial, and delays 200 ms. This targets approximately 5 Hz plus processing time. The values are raw 12-bit ADC readings, not calibrated force, mass, or pressure units.

There is no Mat calibration command, tare procedure, per-channel gain normalization, or moving-average filter in this primary sketch. The physical meaning of lower support channels in different poses must be confirmed from the actual setup; the source labels them feet.

## BLE comparison against the actual App parsers

The comparison used the original project's `YogaApp/BLEManager.swift`, `YogaApp/YORIFlexBLEManager.swift`, and `YogaApp/PracticeResultScreens.swift`. These transport/UI files were inspected but are **not included** in the requested eight-file Swift selection. Their inspection hashes are in the manifest. This section describes the existing contract; it does not define a replacement protocol.

### Device identity and characteristics

| Device / role | Firmware declaration | Actual App handling | Inspection result |
| --- | --- | --- | --- |
| Flex advertised name | `YORI-Garment` | Accepts `YORI-Garment` or `YORI Flex`. | Match; different UI branding is not a discovery mismatch. |
| Flex service | `2F3A0001-7D9A-4C3B-9A21-1234567890AB` | Same service UUID. | Match. |
| Flex MAIN | `2F3A0002-7D9A-4C3B-9A21-1234567890AB`, Notify | Discovers, subscribes, and parses MAIN. | Match. |
| Flex gyro | `2F3A0003-7D9A-4C3B-9A21-1234567890AB`, Notify | Discovers, subscribes after MAIN notification setup, and parses gyro. | Match. |
| Flex acceleration | `2F3A0004-7D9A-4C3B-9A21-1234567890AB`, Notify | Requests characteristic discovery, but does not subscribe or parse acceleration. | Firmware capability is not connected to App evaluation. |
| Flex control | `2F3A0005-7D9A-4C3B-9A21-1234567890AB`, Write | Writes UTF-8 `CAL`; prefers a write with response. | Command and characteristic match; no calibration-complete handshake. |
| Mat advertised name | `YORI_ESP32` | Requires `YORI_ESP32`. | Match. |
| Mat service | `12345678-1234-1234-1234-1234567890ab` | Same service UUID. | Match. |
| Mat data | `abcd1234-5678-1234-5678-abcdef123456`, Read + Notify | Subscribes to Notify and parses the text value. | Match; Read is not needed by the current path. |

### Flex MAIN layout: 18 bytes

The firmware uses `#pragma pack(push, 1)` and sends the struct's native bytes. For the intended ESP32 target this is compatible with the Swift parser's explicit little-endian decoding. The sketch does not implement portable endian serialization for arbitrary future targets.

| Byte offset | Field | Wire type / scale | Swift interpretation |
| --- | --- | --- | --- |
| 0 | sequence | `uint16_t` | `UInt16`; used for MAIN/gyro pairing. |
| 2 | T3 roll | `int16_t`, degrees x100 | Signed value /100.0, degrees. |
| 4 | T3 pitch | Same | Same. |
| 6 | T12 roll | Same | Same. |
| 8 | T12 pitch | Same | Same. |
| 10 | S1 roll | Same | Same. |
| 12 | S1 pitch | Same | Same. |
| 14 | EMG 1 | `int16_t`, rounded mV | Signed value, no extra scale applied. |
| 16 | EMG 2 | Same | Same. |

`parseSensorPacket()` requires exactly 18 bytes. `scaleValue()` rounds and saturates scaled angle values to the signed 16-bit range. The transmitted angles are relative to the firmware calibration, not absolute orientation measurements.

### Flex gyro and acceleration layouts: 20 bytes each

| Byte offset | Field order | Gyro representation | Acceleration representation |
| --- | --- | --- | --- |
| 0 | sequence | `uint16_t` | `uint16_t` |
| 2, 4, 6 | T3 x, y, z | Signed degrees/second x10 | Signed g x10000 |
| 8, 10, 12 | T12 x, y, z | Same | Same |
| 14, 16, 18 | S1 x, y, z | Same | Same |

`parseGyroscopePacket()` requires exactly 20 bytes and divides signed values by 10.0, matching the sketch. Acceleration has the same field order with a different scale, but no App parser consumes it. All three firmware packets use the same sequence number for a successful sample; the number increments afterward.

BLE packets do not carry the firmware timestamp. The App timestamps receipt. Cat-Cow pairs only the latest MAIN and gyro samples whose sequence numbers match and avoids reprocessing the same sequence. It does not maintain a reorder buffer or backfill missed pairs.

### Mat text format and units

The value has this structure, with decimal integer readings:

```text
LH:<integer>,RH:<integer>,LF:<integer>,RF:<integer>
```

`BLEManager.parsePressurePacket()` splits comma-separated key/value pairs, requires all four keys, and produces integers without rescaling. This matches the primary Mat firmware. There is no sequence number, device timestamp, checksum, or calibration metadata in this value.

The App's current live evaluation uses left/right ratios of these raw readings. The separate original `PressureMetricsCalculator.swift` with ten-sample smoothing and channel reference values is not used by this live path and is not included here.

## Discrepancies and integration concerns

No mismatch was found in accepted device names, UUIDs, MAIN/gyro field ordering, signed interpretation, or implemented MAIN/gyro scale factors. The following gaps remain; no code was changed to resolve them.

| Finding | Evidence and effect | Verification status |
| --- | --- | --- |
| Calibration blocks longer than the App's liveness threshold. | Flex `calibrateAll()` includes 2000 ms plus three sets of 60 x 10 ms delays: at least about 3.8 seconds, plus I2C and serial work. Normal MAIN/gyro notifications stop during this work. The original Flex manager's `mainStreamStaleInterval` is 2.0 seconds, checked every 0.5 seconds, without a calibration exemption. Expected calibration silence can therefore initiate resubscription and potentially reconnect. Startup calibration also follows BLE advertising initialization. | Timing conflict confirmed in source; actual recovery transitions need a paired-device trace. |
| Calibration completion is not acknowledged over BLE. | The App's `sendCalibrationCommand()` returns after scheduling a write. The UI waits 0.8 seconds and then counts down for 3 seconds. The firmware reports completion/warnings only over serial. A BLE write acknowledgement is not proof that all three calibration operations succeeded. The roughly 3.8-second UI schedule leaves no demonstrated margin beyond the firmware's explicit delays. | Missing handshake confirmed; resulting start timing needs runtime validation. |
| Acceleration is published but unused by the App. | Firmware sends `AccelPacket`; App discovery includes its UUID but notification setup and value parsing handle only MAIN and gyro. | Confirmed source-level connection gap, not a MAIN/gyro format mismatch. |
| Mat notification size depends on BLE payload capacity. | Four four-digit ADC values produce a 31-byte text value. That exceeds the 20-byte payload associated with a default ATT MTU of 23. No explicit MTU setup or application-level chunk reassembly was found in the compared code. | Negotiated MTU and actual delivery/truncation are not verified; this is not a claim that current transfers fail. |
| Sensor validity is not encoded. | Flex skips output on IMU-read failure, returns zero EMG if ADC initialization failed, and reports calibration warnings only over serial. App freshness detects missing packets but cannot distinguish all sensor faults from valid numeric readings. | Confirmed format limitation; error behavior on hardware unverified. |
| USB analysis is a separate, incompatible path for the supplied primary outputs. | The original pressure scripts expect whitespace-separated `LH:... RH:...` serial fields. This primary Mat sketch prints comma-separated fields. Flex prints a different CSV schema. No matching Flex serial recorder was found in the previously inspected pressure scripts. These scripts and experiments are excluded from this collection. | Source-format mismatch confirmed; it does not affect the Mat BLE parser, which expects commas. |

The two sketches have closing braces at end of file and no trailing newline. This formatting is preserved; it is not a missing-brace finding or a compile result.

## App-side evaluation, scoring, and feedback flow

The full project connects the selected core to omitted transport, UI, persistence, and optional AI services:

```text
Flex IMUs + EMG ADC --> Flex BLE MAIN + gyro -----+
                                                |
Mat analog channels --> Mat BLE text ------------+
                                                v
                       Original App BLE managers [not included]
                                                v
                       YORILiveSensorModels
                                                v
                       YORILiveEvaluationManager
                                                v
                       YORIPoseEngine
                         |             |                 |
                         v             v                 v
                    Live feedback   Session scoring   Intervention decisions
                         |             |                 |
                         v             v                 v
                    Original UI     Score calibration  Original AI/voice pipeline
                    [not included]      |              [not included]
                                        v
                                   Final result
                                        |
                                        v
                         Original UI / SwiftData storage [not included]
```

### Preparation and live evaluation

`YORIStartingPositionStabilityDetector.ingest()` evaluates six roll/pitch series over a 1.5-second window. It requires at least eight samples spanning at least 1.05 seconds, with maximum angle standard deviation <=1.0 degree and first-to-last drift <=1.875 degrees. It uses orientation rather than gyro for this preparation gate and does not judge pose correctness.

In the original UI, a stable window supplies Cat-Cow EMG baseline medians, triggers the firmware `CAL` command, and precedes the countdown. This UI orchestration is documented for context but not copied into this collection. Firmware angle-zero calibration and App EMG baseline normalization are distinct operations.

`YORILiveEvaluationManager` observes both original BLE managers through Combine. It clears Flex live samples/results and resets the Cat-Cow window when MAIN freshness is lost. Mat data is optional. Pausing stops evaluation and session aggregation; Cat-Cow timestamps subtract paused duration.

The user selects the pose in the original App. This core evaluates that selected Mountain or Cat-Cow pose; it is not a general classifier that automatically identifies arbitrary exercises.

- **Mountain:** `evaluateMountain()` derives upper/lower spine pitch and roll differences. Ordered prototype pitch rules produce posterior pelvic tilt, anterior pelvic tilt, rounded upper back, or correct. Optional foot pressure supplies symmetry.
- **Cat-Cow:** `ingestCatCowFrame()` / `evaluateCatCowWindow()` use approximately 16 seconds of paired MAIN/gyro data. Upper/whole-spine range and combined gyro RMS determine incomplete range and/or poor control. Both issues may coexist. Optional hand pressure supplies symmetry. Relative EMG activation is reported as a baseline-relative percentage change, not a clinical measure or a score input.
- **Pressure:** `pressureDistribution()` calculates left/right load percentages and `100 - abs(leftPercent - rightPercent)` symmetry from the supplied readings. No physical force conversion is implemented in this path.

### Session scoring

`YORISessionEvaluator` collects only active-session data. Mountain requires at least one second, ten MAIN samples, and ten gyro samples. Cat-Cow requires at least three sufficiently filled window evaluations spanning at least one second; evaluation collection is throttled to 0.5-second intervals. Insufficient data returns no result.

- Mountain raw Alignment combines classification proportions and continuous angle deviation. Raw Stability uses orientation/relative-angle variation and drift. Raw Control uses gyro RMS/peak, correction events, and state switches.
- Cat-Cow raw Alignment uses range completion and incomplete-range frequency. Raw Stability uses consistency of ranges and gyro RMS. Raw Control uses mean gyro RMS quality, the 90th percentile of window gyro peaks, and poor-control frequency.
- Valid pose-specific Mat symmetry contributes 15% of raw Stability when available; otherwise Flex-only stability is used.
- `YORIScoreCalibrator` maps raw dimensions using fixed prototype interpolation anchors. For bounded raw inputs of 0...100, Alignment maps to 55...97 and Stability/Control to 65...97. Overall is the mean of the three calibrated dimensions. Displayed scores are not direct raw-accuracy percentages.
- Deterministic final feedback is selected from raw dimensions and supporting metrics. EMG does not currently contribute to these scores. Raw score fields are Debug-only.

The thresholds and score curves are prototype development choices, not validated pediatric norms or medical criteria. No physical accuracy or clinical claims are established by this source inspection.

### Feedback and intervention decisions

`YORIActivePracticeFeedbackPresenter` maps engine results to short screen messages. Mountain state changes use a 0.75-second debounce; Cat-Cow handles no issue, either issue, and both issues without forcing a single classification.

`YORIInterventionDecisionEngine` requires persistent issues before producing a trigger. Mountain uses 2.5 seconds; Cat-Cow uses three meaningful observations at least one second apart, spanning at least two seconds. Recovery gates, an 18-second same-issue cooldown, a 9-second global cooldown, user interaction, and voice-busy inputs control eligibility. Recording delivery/recovery is part of the caller's responsibilities.

This selected decision engine does **not** perform networking or audio playback. In the full project, omitted `YORIAutomaticCoachCoordinator`, `YORIAutomaticPlaybackGate`, `YORIAIContextAssembler`, `YORIAICoachClient`, and `YORICoachVoicePlayer` connect triggers to context checks, AI text, cloud speech, and local speech fallback. The selected collection alone cannot provide an AI conversation or speak a cue.

Likewise, original `ContentView` / `TrainingSession` code saves successful summaries to SwiftData, but those files and all user records are excluded here.

## Build status and required dependencies

### Collection as a whole

**This collection cannot build independently as an App.** It has no Xcode project, Swift package manifest, App entry point, UI, assets, transport managers, or complete dependency graph. In particular, `YORILiveEvaluationManager.swift` references omitted `BLEManager`, `YORIFlexBLEManager`, and their connection-state types. No replacement stubs were added.

The Swift sources require Apple's Foundation, Combine, and OSLog frameworks and a compatible Apple toolchain. The original project uses Swift 5 language mode and an iPhone target with an iOS 26.0 deployment setting. These are original project settings, not proof of the minimum SDK that an extracted library could support. Integrating or packaging the core as a separate module would require additional work.

Existing Debug development checks remain in the copied files. They were not executed during this preparation and do not make the selection a standalone test suite.

### Individual firmware sketches

Each sketch has an Arduino-compatible folder/filename arrangement and its own `setup()` / `loop()`. They can be considered separately from the App, but successful compilation and flashing have **not** been established. Supply the actual board profile and compatible dependencies before attempting either.

| Dependency | Used by | How it is supplied |
| --- | --- | --- |
| Arduino IDE or Arduino CLI | Both sketches | External build tool; not copied. |
| Espressif Arduino-ESP32 board core | Both sketches | Provides Arduino APIs and the BLE implementation matching `BLEDevice.h`, `BLEServer.h`, `BLEUtils.h`, and `BLE2902.h`. Exact version is unpinned. |
| Wire / I2C support | Flex | Provided by the selected ESP32 Arduino core. |
| C/C++ math support | Flex | Toolchain/core facilities for `atan2`, `sqrt`, `sin`, `cos`, and `roundf`. |
| DFRobot ADS1115 0-10V library exposing `DFRobot_ADS1115_0_10V.h` and `DFRobot_ADS1115_I2C` | Flex | Install the matching external library; exact version and API compatibility are unverified. |
| Confirmed board profile and wiring | Both sketches | Flex source identifies ESP32-S3; exact variant remains unspecified. Mat exact board remains unspecified. |

The Flex sketch accesses MPU registers and the multiplexer directly; it does not include a separate MPU or TCA driver library. Do not replace the indicated ADC library with a generic ADS1115 package without checking API and unit compatibility. No entire Arduino `libraries` directory or installed dependency tree is included.

## Excluded material

- All sketches under `Firmware/experiments`, including `YORI_Mat_Analog_Test`, `YORI_IMU_Calibration_Test`, and `YORI_Mat_USB_Test`. They are development references, not part of this minimal selection.
- Other Swift files, the full Xcode project and signing/account configuration, UI assets, backend implementation, and pressure-analysis scripts.
- `.env` files, tokens, credentials, personal paths/configuration, recorded CSV data, user databases, audio recordings, and device-specific stored identifiers.
- `node_modules`, Arduino libraries, caches, build products, editor state, `.DS_Store`, and Git history.
- Unrelated projects and design/process documents from the parent repository.

The included source was reviewed for credential literals and personal-record content. No such content was identified in the allowlisted copies. This is a scoped inspection of these files, not a certification of the parent repository or its history.

## Public portfolio repository

This collection is intended for public portfolio review at [lexieyin12-dotcom/YORI-Core-Code](https://github.com/lexieyin12-dotcom/YORI-Core-Code). The project owner authorized public publication of the 13 selected files, including the scoring rules and both primary firmware sketches.

The repository root contains only this collection, with an independent Git history. The parent YogaApp repository and its history are excluded. This selection exposes the inspected implementation for review; it does not include the full App, a validated hardware build, or evidence of verified runtime behavior. Future updates should preserve the source manifest and documented limitations, and must not overwrite unrelated remote work.

`SOURCE_MANIFEST.json` allows later comparison with the original files. Re-check protocol findings against the matching firmware/App revisions before treating this snapshot as a reproducible hardware integration.

## Preparation checks completed

- Confirmed an exact allowlist of 13 files: ten selected sources, this README, the source manifest, and the collection's `.gitignore`.
- Compared every copied source byte-for-byte with its original and checked SHA-256 digests against the pre-copy snapshot.
- Rechecked all selected files for Chinese text during finalization; none was found, and no source comments were translated. Separate original/exported hashes in the manifest confirm that source copies remain identical.
- Confirmed that the three original protocol-reference files remained unchanged.
- Checked both sketch folder/filename pairs and every relative file link in this README.
- Compared BLE UUID sets and accepted device names; checked packed field declarations and calculated MAIN / gyro / acceleration sizes of 18 / 20 / 20 bytes. These are static structure checks, not compiled ABI or over-the-air tests.
- Confirmed that experiments, credentials/configuration files, personal records, installed dependencies, caches, and Git history were not copied. No credential signatures or personal absolute paths were identified in the selected text files.

No independent App build, Arduino compile, firmware flash, or physical integration test was performed. The runtime concerns above remain open.
