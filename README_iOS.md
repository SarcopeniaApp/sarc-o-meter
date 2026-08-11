# Body Measure — on-device test app

The smallest thing that runs the whole non-manual pipeline on your iPhone:
enter height/weight, add a front + side photo, and the app segments them,
runs the Core ML model, and shows the 14 measurements. Every stage is streamed
to a folder on your Mac so you can debug it the same way as the Mac pipeline.

## Files

| file | role |
|---|---|
| `BMNetPredictor.swift` | segmentation + build the model input + Core ML inference (the core) |
| `DebugLog.swift` | streams text + images to the Mac debug server (and os_log) |
| `ImagePicker.swift` | camera / photo-library picker + upright-orientation fix |
| `ContentView.swift` | the one screen |
| `SarcxeyApp.swift` | app entry (`@main`) |
| `../tools/debug_server.py` | **runs on the Mac** — receives and saves every stage |
| `../models/bmnet.mlpackage` | the trained model |

## Build it (≈5 minutes in Xcode)

1. **New project** → iOS → App → SwiftUI. Name it whatever.
2. The template creates its own `@main App` file (e.g. `YourNameApp.swift`) and a
   `ContentView.swift`. **Only one `@main` is allowed**, so either:
   - delete the template's App file and add `SarcxeyApp.swift`, **or**
   - delete `SarcxeyApp.swift` and paste its `WindowGroup { ContentView() }` body
     into the template's App file.
   Then delete the template `ContentView.swift`.
3. **Add these files** to the target (drag into the project, "Copy items if
   needed", target checked): `BMNetPredictor.swift`, `DebugLog.swift`,
   `ImagePicker.swift`, `ContentView.swift` (+ `SarcxeyApp.swift` per step 2).
4. **Add the model**: drag `models/bmnet.mlpackage` in, target checked. Xcode
   compiles it to `bmnet.mlmodelc` in the bundle automatically.
5. **Info.plist** — add these keys (Signing & Capabilities → Info, or edit
   Info.plist source):

   | key | value | why |
   |---|---|---|
   | `NSCameraUsageDescription` | "Take body photos for measurement." | camera |
   | `NSPhotoLibraryUsageDescription` | "Pick body photos for measurement." | library |
   | `NSLocalNetworkUsageDescription` | "Send debug logs to the Mac." | debug POST |
   | `NSAppTransportSecurity` → `NSAllowsLocalNetworking` = `YES` | | allow http to the Mac |

6. **Signing**: pick your team, plug in your iPhone, select it as the run target.
7. **Run** (⌘R) on the device.

## Watch it on the Mac

1. On the Mac, same Wi-Fi as the phone:
   ```bash
   python3 tools/debug_server.py
   ```
   It prints a URL like `http://10.0.0.12:8000`.
2. In the app, paste that URL into **Debug server**. (It's remembered.)
3. Measure. The Mac console prints each stage live, and everything lands in
   `tools/debug_runs/<timestamp>/`:
   - `00_front.png`, `00_side.png` — the input photos
   - `01_seg_front.png`, `01_seg_side.png` — Vision person masks
   - `03_silhouette.png` — **exactly what the model sees** (joined front|side)
   - `log.txt` — inputs, the 14 measurements, timing, warnings

   Open `03_silhouette.png` first when a result looks off — a bad silhouette is
   almost always the cause, and you'll see it immediately.

The debug server is optional: leave the field blank and everything still logs to
the Xcode console via os_log (filter by subsystem `com.sarcxey.bmnet`).

## Using it well

- **A-pose, feet apart, fill the frame head-to-toe**, front then a 90° side view —
  that matches the training data and keeps the segmentation clean.
- **Calf is highlighted** but remember: for the clinical (sarcopenia) decision,
  a tape measure beats the photo estimate. The photo calf is a convenience value.
- A first inference may take a moment while Core ML warms up; subsequent ones are
  fast.

## What this is not (yet)

The camera flow here is a plain picker. The **auto-capture** version — live body-
pose detection that snaps the photo when you hit an A-pose / side pose — is the
next layer, and it sits on top of this exact predictor. This app exists to prove
the model path end-to-end on-device first.
