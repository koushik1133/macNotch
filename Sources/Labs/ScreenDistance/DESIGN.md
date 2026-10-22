# Screen Distance (SparkV Labs)

An opt-in Mac version of iOS Screen Time's **Screen Distance**. When your face
stays closer than a set distance for a while, a full-screen notice says the
screen is too close and lets you continue only after you move back. Distance
comes from the FaceTime camera and Vision face landmarks, the same approach
glance (github.com/jonnyoo/glance, MIT) uses for its own interocular-distance
and too-far checks. Nothing here imports GlanceKit; the geometry is
re-implemented in `ScreenDistanceMath.swift` so the feature is independent of
Face Unlock.

## What Apple's feature does

From Apple's support articles "What is Screen Distance?" (support.apple.com/105007)
and the macOS Screen Time help page "Turn on Screen Distance" (mchle20721bd):

| Apple (iPhone/iPad, iOS 17+) | SparkV (Mac) |
| --- | --- |
| Uses the TrueDepth camera to detect a device held **closer than 12 in / 30 cm** | FaceTime HD camera + Vision landmarks; default **40 cm**, adjustable 30 to 60 cm (a laptop sits farther from the eyes than a phone) |
| Triggers after an "extended period"; Apple publishes no number (reviews report anything from seconds to a few minutes) | **8 seconds** of continuous closeness (the task's spec) |
| An alert **covers the screen** and blocks you from continuing | Blurred, dimmed non-activating key `NSPanel` on every display at `statusBar + 1`; it takes the keyboard without activating SparkV and takes it back if you Cmd-Tab away while still too close |
| You move the device away, a checkmark appears and **Continue** becomes available; moving away clears it | Continue is disabled until you are farther than threshold + 5 cm; then a checkmark shows and the notice **fades out by itself after 1.5 s** |
| No way to skip | Esc does nothing (a beep) unless **Allow skipping** is on; a skip then holds off new warnings for 5 minutes or until you have moved back once. **Snooze 15 min / 1 hour** buttons on the notice and in the gear menu |
| Off by default for adults, on for children under 13 in Family Sharing | **Off by default**; camera permission is requested only when you switch it on |
| Apple: "There are no alerts if you're viewing your Mac too closely." | This fills that gap |
| Reviewers report it takes no photos and processes on device (Apple's support page itself says nothing about privacy) | Frames analysed in memory and dropped; no images, no face data stored; only settings, one calibration number and daily totals in UserDefaults |

Sources:
- Apple, "What is Screen Distance?" https://support.apple.com/105007
- Apple, macOS User Guide, "Turn on Screen Distance" https://support.apple.com/guide/mac-help/mchle20721bd/mac
- Tom's Guide, "iOS 17 has a new eye strain reduction feature" https://www.tomsguide.com/news/ios-17-has-a-new-eye-strain-reduction-feature-heres-how-it-works
- SlashGear, "How to set up Screen Distance in iOS 17" https://www.slashgear.com/1420370/how-iphone-screen-distance-safety-ios-17
- Digital Citizen, "Screen Distance on iPhone" https://digitalcitizen.life/screen-distance-iphone

### Why 40 cm on a Mac

Laptop and desktop viewing guidance is much farther than phone guidance:
- CCOHS (Canadian Centre for Occupational Health and Safety), "Positioning the
  Monitor": ideal eye-to-screen distance **40 to 74 cm**, about arm's length;
  resting point of accommodation about 80 cm.
  https://www.ccohs.ca/oshanswers/ergonomics/office/monitor_positioning.html
- OSHA computer workstations eTool, as quoted by secondary sources (not
  checked on osha.gov in this pass): 50 to 100 cm (20 to 40 in) from the eye
  to the screen.
- CSA Z412 office ergonomics guideline (quoted by CCOHS-based material): 400 to
  740 mm for prolonged viewing.

40 cm is the near edge of every one of those ranges, so a warning below it
is conservative (it does not nag someone at a normal 50 to 70 cm). The
setting goes from 30 cm (Apple's phone value) to 60 cm.

## Distance estimation

Pinhole camera model. With horizontal field of view `FOV` and a frame `W`
pixels wide, the focal length in pixels is

    f = (W / 2) / tan(FOV / 2)                 // 640 px at 72° → 440.4 px

Eye centres come from Vision `VNDetectFaceLandmarksRequest` (pupil point
when present, else the centroid of the eye contour), in image pixels. The
interocular distance `ipd_px = hypot(Δx, Δy)` (roll-invariant). With an
average adult interpupillary distance of 6.3 cm (Dodgson 2004, mean 63 mm):

    distance_cm = f × 6.3 / ipd_px

Corrections, derived for 3D eyes rotated by head yaw α at depth Z and
horizontal off-axis angle θ (tan θ = X / Z):

    ipd_px ≈ f × IPD × cos ψ / (Z × cos θ),   ψ = α + θ = the yaw Vision sees

- **Yaw:** divide `ipd_px` by `cos ψ` using `VNFaceObservation.yaw`; faces
  turned more than 35° are rejected (`.faceTurned`) instead of corrected.
- **Off-axis:** divide the result by `cos θ`, θ from the eyes' midpoint, so
  the value is the depth from the screen plane.
- **Several faces:** the one with the largest `ipd_px` (closest) wins.
- **Plausibility:** results outside 10 to 200 cm are dropped as detection errors.

Harness check: a sweep over 25 to 90 cm, yaw ±30°, heads up to 20 cm
off-centre (327 accepted poses, 65 rejected as turned) stays within **0.73 %**
of the true depth; without the yaw correction the error reaches 15.5 % at 30°.

**Field of view on macOS.** `AVCaptureDevice.Format.videoFieldOfView` is
`API_UNAVAILABLE(macos)`, and camera intrinsics delivery is iOS-only. The
camera reads `kCMFormatDescriptionExtension_HorizontalFieldOfView` if the
format carries it, else uses a nominal **72°** horizontal FOV for the native
16:9 FaceTime HD format (about 80° diagonal), scaled for narrower aspect ratios
on the assumption that they are side crops (4:3 → 57.2°). To keep that
assumption safe, the camera selects the smallest native **16:9** format at
least 640 px wide and scales frames to 640×360, so nothing is cropped.

**Calibration** (optional, one step). Sit at your usual distance and either
measure it with a ruler or accept 50 cm, then press Calibrate. A 12-frame
burst gives the uncalibrated median `m`; the stored factor is
`scale = actual / m`, clamped to 0.5 to 2. This absorbs both the FOV guess and
your own IPD (a 5.8 cm IPD reads 54.3 cm at a true 50 cm uncalibrated).
Stored as `screenDistance.calibrationScale` in UserDefaults.

**Smoothing.** Each burst is 5 analysed frames; its median is one reading
(at least 2 frames must have a face). Readings then go through a median of
the last 3 values no older than 4 s. At the 5 s cadence each burst stands
alone (no lag); during the 2 s "approaching" cadence and the 4 fps stream
while the notice is up, the median of 3 removes single-frame spikes.

## Decision logic (`ScreenDistanceTracker`)

    safe ──d < T──▶ approaching(since) ──still d < T at since + 8 s──▶ alerting
      ▲                 │ d ≥ T, or no close reading for 12 s            │ d > T + 5
      └─────────────────┘                                               ▼
      ◀── 1.5 s later, or Continue ─────────────────────────────  cleared (Continue on)
                                                       d < T again ─▶ back to alerting

- No face (or a face turned past 35°) during a warning keeps it up
  ("Looking for your face…"); after 20 s without one it ends (you left the desk).
- Between T and T + 5 cm a cleared notice stays cleared (hysteresis).
- Esc / Skip ends a warning while still close only when Allow skipping is on,
  and then no new warning starts for 5 minutes unless you first move back past
  T + 5 (otherwise Skip would be pointless: the warning would return 8 s later).
  Continue starts no cooldown, as on iOS.

## The notice can't trap you

Every path out was tested with a fake camera and clock:
- back past T + 5 → "That's better", fades 1.5 s later;
- no usable face for 20 s (left, turned away, camera stopped delivering) → ends;
- the live stream goes silent → a watchdog restarts it after 4 s, and the
  20 s rule still ends the notice if no frame ever arrives;
- feature switched off, Pause, Snooze (buttons on the notice itself), screen
  lock, display or system sleep, fast user switch, the mirror or Face Unlock
  taking the camera, permission revoked, `stop()` → notice, band and camera
  go at once (lock and sleep don't wait for the loop's next step);
- the overlay also checks the controller every second and removes itself if
  no warning is active, whatever happened to the loop;
- a panel fading out stops intercepting clicks immediately.

## Sampling, battery and privacy

- **Off by default.** `AVCaptureDevice.requestAccess` is called only when the
  user switches the feature on or presses Calibrate; the loop itself never
  prompts. Denied → state `.noPermission` with a button to Privacy settings.
- **Bursts, not a live camera.** Every 5 s (5/10/30 s setting) the session
  starts, drops 4 warm-up frames (auto exposure), analyses 5 frames at
  640×360 and stops. The camera, and its green light, are on about a second
  per burst. While "approaching" the cadence is 2 s so the 8 s trigger is
  accurate (it fires at 8 to 10 s). Only while the notice is up does the
  camera stay on, at 4 analysed frames per second, so the notice can update
  and clear itself.
- **Never fights for the camera.** A burst is skipped when
  `AVCaptureDevice.isInUseByAnotherApplication` is true (calls, recordings),
  when the host's `isCameraBusy` hook says the mirror or Face Unlock has it,
  and `yieldCamera()` drops a burst at once.
- **Pauses:** screen locked (`com.apple.screenIsLocked`), displays asleep,
  system sleep, fast user switch (tracked as separate flags so one wake event
  can't clear another), snooze (persisted), Pause from the notch, optionally
  on battery at or below 20 % (IOKit power sources), during calibration, and
  while **Center Stage** is active for SparkV (see below).
- **Center Stage.** On cameras that support it (the 12 MP Center Stage camera
  of recent MacBook Pros), Center Stage pans and zooms, so the field of view
  and focal length change from frame to frame and distances would be wrong
  (a zoomed-in face looks closer). Frames taken while
  `AVCaptureDevice.isCenterStageActive` is true are marked `isReframed` and
  give no distance; the controller pauses with "turn off Center Stage for
  SparkV" and retries every 30 s. SparkV does not change the app-wide Center
  Stage setting itself, since that would also affect the camera mirror.
- **Nothing saved.** Pixel buffers are analysed in memory by Vision and
  released; no frame, crop, landmark or embedding is written anywhere. The
  only stored data: preferences, the calibration factor, snooze time and
  per-day totals (seconds too close, number of warnings, kept 14 days).
- **On device.** Vision runs locally; there is no network code in this folder.

## Daily stats

`ScreenDistanceStatsLog` adds the time between two consecutive close readings
(at most `max(15 s, 2.5 × interval)` apart, so pauses aren't counted), split
at midnight in the user's calendar, plus one warning per notice. The drawer
shows "Today: 12 min too close · 3 warnings"; the controller re-reads the
day on every loop step, so the numbers roll over at midnight on their own.

## Files

| File | What |
| --- | --- |
| `ScreenDistanceMath.swift` | Pinhole math, yaw/off-axis correction, burst median, calibration, smoother |
| `ScreenDistanceTracker.swift` | Threshold/8 s/hysteresis state machine; daily stats log |
| `ScreenDistanceSettings.swift` | UserDefaults settings; battery check |
| `ScreenDistanceCamera.swift` | AVCaptureSession bursts/stream + Vision landmarks (`ScreenDistanceSampling` protocol) |
| `ScreenDistanceController.swift` | `@MainActor ScreenDistanceController`: loop, pauses, permission, notice, band, stats |
| `ScreenDistanceOverlay.swift` | Full-screen blocking notice (`NSPanel` per screen) |
| `ScreenDistanceViews.swift` | Band, gauge, drawer tab, gear-menu items, settings section |

## Known limits

- The 72° FOV is nominal; without calibration absolute numbers can be off by
  roughly ±10 % (FOV) and ±8 % (individual IPD, adult range about 5.4 to 7.4 cm).
  Recent MacBook Pros with the 12 MP Center Stage camera may differ more:
  calibrate once on the real machine.
- Not run against the real camera or a real face in this pass (harness rule:
  no camera, no photos of people). Vision was exercised on rendered emoji
  faces: landmarks found, eye spacing scales with face size (median error 3 %).
- Whether Vision's `yaw` is continuous or quantized for live faces was not
  verified here; if it reads 0 for an off-centre frontal face, the off-axis
  step over-estimates by 1/cos θ (1.5 % at 10° off-centre, 4 % at 16°,
  10 % at 25°). Someone sitting in front of a laptop is usually within 10°.
- The camera's green light flashes about a second every 5 s while enabled.
  That is the honest cost of a webcam-based feature; the interval can be
  raised to 10 or 30 s.
