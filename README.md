# SplineMaker

![icon-banner](https://github.com/jeinselen/Godot-SplineMaker/blob/main/icon-banner.jpg)

SplineMaker is an experimental passthrough XR spline sketching tool for Meta Quest 3, built with Godot 4.7.2, OpenXR, and the mobile Vulkan renderer. Draw and edit spline-based forms in-headset with the Touch controllers or a Logitech MX Ink stylus, then round-trip project data into Blender.

Projects export as clean `.json` files when closed. Blender import/export is handled by the SplineMaker Project I/O add-on in [DeliveryKit](https://github.com/jeinselen/Blender-DeliveryKit).

## Feature Overview

- Passthrough OpenXR app for Meta Quest 3
- Draw with either Touch controller or a **Logitech MX Ink stylus** (ambidextrous, fully independent)
- Realtime spline drawing with adjustable smoothing and live tube-mesh preview
- Stroke width from **pressure or drawing speed**, shaped by a **sensitivity** curve
- Trigger-based endpoint extrusion and midpoint insertion
- Grip-based point transforms (translate, rotate, scale relative to the controller)
- Joystick per-point `size` and `weight` editing with on-screen numeric feedback
- **Mirror and radial symmetry** (per-project, live)
- **Position / size / weight snapping** with adjustable steps
- In-headset **virtual keyboard** for text and numeric entry
- File-based autosave history with undo/redo
- JSON export to `Documents/Splines/` on project close
- Blender round-trip through the DeliveryKit add-on

## In-Headset Workflow

1. Launch the app and create a new project or import an existing SplineMaker JSON file.
2. Draw in empty space with a controller or the stylus to create a spline.
3. Hover control points to extrude, insert, move, resize, reweight, or delete them.
4. Use the project panel to switch `Size`/`Weight` mode, adjust smoothing and sensitivity, pick pressure or speed, select splines, edit `Order U`/`Cyclic`, and open the Snapping and Mirroring sub-panels.
5. Close the project to export a fresh JSON file for Blender.

## Controller Interactions

Both controllers behave the same — usage is ambidextrous and independent. The only exception is the `Menu` button (left controller only), which resets the view.

- **Panels**
  - Aim ray + `Trigger` = click buttons, sliders, and lists
  - Aim ray + `Joystick` = scroll lists
  - Aim ray + `Grip` = move panel (or grab its edge with `Grip`)
- **Project space**
  - `Trigger` = draw a new spline (pressure/speed sets stroke width; the `Smoothing` slider controls point density)
  - `Joystick` = adjust size of the action area
  - `Grip` = move and rotate the project space (both grips together = move, rotate, and scale)
  - `A`/`X` = undo, `B`/`Y` = redo
- **Points** (when one or more are within the controller's active area)
  - `Trigger` = extrude endpoints or insert a midpoint (endpoints take priority; if only midpoints are in range, the lowest-index one is used)
  - `Joystick` = adjust point size or weight (mode set in the project panel)
  - `Grip` = move and rotate the active point(s); hold `Grip` + `Joystick` to scale multiple points
  - `A`/`X` = delete point(s) in the action area

## MX Ink Stylus

The Logitech MX Ink stylus is supported natively on **Quest 3 / 3S (Meta OS v68+)** — no extra setup or SDK. It takes over one hand slot and works alongside a Touch controller in the other hand. Undock it to use it; dock it to return to two-controller mode.

- **Tip / side pad (pressure)** — the primary "draw/grab" gesture
  - Empty space = draw (tip force or drawing speed sets width)
  - Hovering points = grab and rotate
  - On a panel = tip clicks buttons, side grabs and moves the panel
- **Front button**
  - Quick tap = redo
  - Hold in empty space = drag left/right to resize the action area; hold while hovering = adjust point size/weight
- **Back button**
  - Quick tap = undo
  - Hold = navigate the view (combine with a controller grip for move/rotate/scale); while hovering = delete points

## Settings

The main menu provides a Settings sub-panel:

- **Export Path** — location of exported / importable JSON files (undo/redo history is internal; only the current state is exported)
- **Undo Steps** — number of undo versions to autosave
- **Autosave Delay** — seconds of inactivity before an undo step is saved (groups rapid edits together)
- **Mesh Resolution** — sides used for the preview tube mesh (higher = smoother, lower = faster)
- **Spline Resolution** — segmentation between control points (Blender defaults to 12; this app defaults to 8 for speed)
- **Max Draw Speed** — hand velocity that maps to the thinnest stroke in Speed mode

Per-project drawing options live in the project panel:

- **Smoothing** — density of control points placed while drawing
- **Sensitivity** — shapes how pressure/speed maps to stroke width
- **Pressure / Speed** — whether width comes from input pressure or drawing speed
- **Snapping** — independent Position, Size, and Weight snapping, each with its own step
- **Mirroring** — mirror across X/Y/Z planes and/or radial symmetry (choose axis and copy count)

## Known Issues

- Project panel placement may not be ideal — just move it.

## Building In Godot

The easiest path is loading the release APK with [SideQuestVR](https://sidequestvr.com/setup-howto). If that doesn't work, build from source. The following covers macOS; Linux and Windows follow similar patterns.

### Prerequisites

- Godot 4.7.2
- Android Studio with its bundled Java runtime and Android SDK configured for Godot Android export
- A Meta Quest 3 with developer mode enabled (may require a Meta developer account)

In Android Studio's `SDK Manager`, install the packages Godot expects:

- Android SDK Platform-Tools `35.0.0` or newer
- Android SDK Build-Tools `35.0.1`
- Android SDK Platform `35`
- Android SDK Command-line Tools (`latest`)
- CMake `3.10.2.4988404`
- NDK `r28b (28.1.13356709)`

The repository includes an Android export preset in [`export_presets.cfg`](export_presets.cfg) named `Quest3`, configured for `Android` / `arm64-v8a`, Gradle build, and OpenXR with the Meta vendor plugin enabled.

### Godot Setup

1. Open the project in Godot 4.7.2.
2. Confirm the editor's Android paths in `Editor Settings > Export > Android`:
   - `Java SDK Path`: `/Applications/Android Studio.app/Contents/jbr/Contents/Home`
   - `Android SDK Path`: `/Users/<your-user>/Library/Android/sdk`
3. Run `Project > Install Android Build Template...` once for the project.
4. Open `Project > Export...` and verify the `Quest3` preset is present with `Runnable` enabled.
5. To produce an APK on disk, export to the preset's default path: `android/SplineMaker.apk`.

## Installing To Meta Quest 3

### Headset Setup

1. In the Meta Horizon mobile app, enable `Developer Mode` for the paired Quest 3.
2. Connect the headset with a USB-C data cable.
3. Put on the headset and accept the `Allow USB debugging` prompt.
4. Verify the connection with `adb devices` (at least one device should be listed).
   - If `adb` is missing, some Android tools likely weren't installed via Android Studio. You can also install it via [Homebrew](https://brew.sh).

### Run From Godot

For debugging, use `Remote Deploy` in the upper right of the window (the TV-with-play-button icon, just right of `Play`/`Pause`/`Stop`). Under the Android section, click your device — Godot builds, deploys, and launches the app with a live debug connection (this can take about half a minute).

### Deploy With ADB

If you exported `android/SplineMaker.apk`, sideload it manually:

```sh
adb install -r android/SplineMaker.apk
```

Launch the app from the headset's "unknown" apps list. It will request storage permission to import and export project files under `Documents/Splines/`.

## Blender Add-on

Blender import/export lives in the **SplineMaker Project I/O** add-on, now part of [DeliveryKit](https://github.com/jeinselen/Blender-DeliveryKit). It imports and exports NURBS curves in the same JSON format used by SplineMaker.

Install it from inside Blender using the [Launch Blender Extensions](https://github.com/jeinselen/Launch-Blender-Extensions) repository — add that repository in `Edit > Preferences > Extensions`, then install DeliveryKit from the list.

To move files between the Quest 3 and a computer, use [MacDroid](https://www.macdroid.app) or a similar Android file-transfer tool.

### Import And Export Workflow

1. For a ready-to-use Geometry Nodes setup with UV mapping and round end caps, open the provided [`samples/NurbsCurve.blend`](samples/NurbsCurve.blend) template (or append its node tree into your project). A sample project is included at [`samples/SplineMaker.json`](samples/SplineMaker.json).
2. Use `File > Import > SplineMaker Project (.json)` to import one or more exported SplineMaker files.
3. Edit the resulting Blender NURBS curves as needed.
4. Use `File > Export > SplineMaker Project (.json)` to write data back into SplineMaker's JSON format.

The add-on handles coordinate conversion between SplineMaker's project space and Blender's curve space automatically, and preserves point radius and weight during round-trip.

## Project Notes

- App state and undo history are stored as incremental JSON saves under `user://projects/`.
- Closing a project writes a clean export JSON to `Documents/Splines/` unless you override the export path in settings.
- OpenXR vendor support is provided through the bundled [`addons/godotopenxrvendors/`](addons/godotopenxrvendors/) plugin.
