# SplineMaker

![icon-banner](https://github.com/jeinselen/Godot-SplineMaker/blob/main/icon-banner.jpg)

SplineMaker is an experimental passthrough XR spline sketching tool for Meta Quest 3, built with Godot 4.6, OpenXR, and the mobile Vulkan renderer. It lets you draw and edit spline-based forms in-headset, then round-trip project data into Blender with the included Blender extension.

The current codebase exports clean project `.json` files on project close. Blender import/export is handled by the extension in [`blender/`](blender/).

## Current Feature Overview

- Passthrough OpenXR app for Meta Quest 3
- Project browser with create, rename, delete, import, and settings workflows
- Realtime spline drawing with progressive smoothing and live tube-mesh preview
- Trigger-based endpoint extrusion and midpoint insertion when hovering control points
- Grip-based point transforms with translation, rotation, and scale relative to the controller
- Joystick-based per-point `size` and `weight` editing modes
- File-based autosave history with undo/redo
- JSON export to `Documents/Splines/` by default when a project closes
- Blender round-trip support through the bundled Blender extension

## In-Headset Workflow

1. Launch the app and create a new project or import an existing SplineMaker JSON file
2. Draw in empty space with either controller to create a spline
3. Hover existing control points to extrude, insert, move, resize, reweight, or delete them
4. Use the in-project panel to switch between `Size` and `Weight`, adjust draw smoothness, select splines, and edit `Order U` or `Cyclic`
5. Close the project to export a fresh JSON file for Blender

## Controller Interactions

Both controllers behave the same, usage is ambidextrous and simultaneously independent. The main exception is the `Menu` button, which is only present on the left controller and resets the view.

- Panels
  - Aim ray + `Trigger` = click panel buttons, sliders, and lists
  - Aim ray + `Joystick` = scroll lists
  - Aim ray + `Grip` = move panel
    - You can also intersect the edge of a panel to grab it with the `Grip` button
- Project space
  - `Trigger` = draw new spline
    - The trigger pressure adjusts the stroke size
    - The action area defines the maximum size of the stroke
    - The `Smoothness` slider in the project panel controls the density of control points placed while drawing new splines
  - `Joystick` = adjust size of action area
  - `Grip` = move and rotate the local project space
    - Use both controller `Grip` buttons at the same time to move, rotate, and scale
  - `A` or `X` = undo
  - `B` or `Y` = redo
- Points (when one or more points are within the active area of the controller)
  - `Trigger` = extrude spline endpoints or insert midpoints
    - If more than one midpoint is within the action area, the first one by index (per spline) will be used as the starting point for the midpoint insertion
    - If one or more endpoints are within the action area, only extrusion will occur (midpoint insertion is ignored)
  - `Joystick` = adjust point size or point weight
    - The mode (size or weight) can be selected in the project panel
  - `Grip` = move and rotate the active point(s)
    - If more than one point is within the active area, you can use the `Joystick` while holding `Grip` to scale the points relative to the controller
  - `A` or `X` = delete point(s) within the action area

## Settings

The main menu provides a settings popup to adjust operating parameters

- Export Path = location of exported / importable JSON project files
  - Undo/redo steps are saved internally, only the current project state is exported or imported
- Undo Steps = number of undo versions to autosave
- Autosave Delay = seconds to wait after an interaction before autosaving an undo step
  - This prevents instantly filling the undo buffer while adjusting point sizes or other edits in quick succession, grouping them based on pauses between data alterations
- Panel Side = which side of the project area the project panel should appear on
- Mesh Resolution = number of sides for preview mesh generation
  - Increase for smoother previews, decrease for faster rendering
- Spline Resolution = segmentation between control points
  - Blender defaults to 12, this app defaults to 8 for faster computation

## Known Issues

- No keyboard appears when attempting to edit strings (affects project naming and the output/input directory location)
- Project panel placement may not be great...just...move it
- Resetting the view doesn't reliably use the current user location, and may send the project space to a different area of the XR space (look around for the axis centre point visual)

## Building In Godot

It's probably easiest to use [SideQuestVR](https://sidequestvr.com/setup-howto) to load the app onto your device. If the release APK file does not work for you, building from source may be necessary. The following assumes building in MacOS, though my path was initially circuitous, and this may or may not be accurate. Similar patterns probably work for Linux or Windows systems.

### Prerequisites

Install the following before exporting to Quest:

- Godot 4.6
- Android Studio with its bundled Java runtime and Android SDK configured for Godot Android export
- A Meta Quest 3 with developer mode enabled (may require Meta developer account creation)

For a minimal macOS setup, Android Studio is enough for both the Java runtime and the Android SDK. In Android Studio's `SDK Manager`, install the packages Godot 4.6 expects:

- Android SDK Platform-Tools `35.0.0` or newer
- Android SDK Build-Tools `35.0.1`
- Android SDK Platform `35`
- Android SDK Command-line Tools (`latest`)
- CMake `3.10.2.4988404`
- NDK `r28b (28.1.13356709)`

The repository already includes an Android export preset in [`export_presets.cfg`](export_presets.cfg) named `Quest3`. It is configured for:

- `Android`
- `arm64-v8a`
- `Use Gradle Build = true`
- OpenXR XR mode with the Meta vendor plugin enabled

### Godot Setup

1. Open the project in Godot 4.6
2. Confirm the editor has the correct Android paths set in `Editor Settings > Export > Android`:
   - `Java SDK Path`: `/Applications/Android Studio.app/Contents/jbr/Contents/Home`
   - `Android SDK Path`: `/Users/<your-user>/Library/Android/sdk`
3. Run `Project > Install Android Build Template...` once for the project
7. Open `Project > Export...` and verify the `Quest3` preset is present and that `Runnable` is turned on
8. If you want an APK on disk (deploying to the headset via `adb`), export to the preset's default path: `android/SplineMaker.apk`

## Installing To Meta Quest 3

### Headset Setup

1. In the Meta Horizon mobile app, enable `Developer Mode` for the paired Quest 3
2. Connect the headset to your computer with a USB-C data cable
3. Put on the headset and accept the `Allow USB debugging` prompt
4. Verify device connection in the Terminal with `adb devices` (at least one device should be listed)
   1. If the command is missing, it's likely some of the android tools were not installed using Android Studio
   2. `ADB` can also be installed using [Homebrew](https://brew.sh) or other command line software manager


### Run From Godot

If you'd like to run directly from Godot, especially for debugging purposes, you can use the `Remote Deploy` in the upper right of the window (it looks like a TV screen with a play button, just to the right of the `Play` `Pause` `Stop` buttons).

Under the Android section you should see the device; click on it. Godot will build the project and load it on the headset with a live debugging connection. This can take a half minute, but the app should automatically open on the device.

### Deploy With ADB

If you exported `android/SplineMaker.apk`, you can sideload it manually:

```sh
adb install -r android/SplineMaker.apk
```

After installation, launch the app from the headset's "unknown" apps list. The app will request storage permission so it can import and export project files to the user's `Documents/Splines/` location

## Blender Extension

The Blender 5.1+ extension allows for importing and exporting NURBS curves in the same JSON format used by SplineMaker. To install, drag-and-drop the extension zip file into a Blender window to install it.

Alternatively, you can also copy the `blender` extension directory from GitHub into one of the Blender extension locations for your local machine.

To transfer files between the Meta Quest 3 and a computer with Blender, use [MacDroid](https://www.macdroid.app) or similar syncing system for Android file transfer (well beyond the scope of this documentation).

### Import And Export Workflow

1. For a ready-to-use Geometry Nodes setup with UV mapping and round end caps, open the provided [`NurbsCurve.blend`](NurbsCurve.blend) template project or append the node tree into an existing project
2. Use `File > Import > SplineMaker Project (.json)` to import one or more exported SplineMaker files
3. Edit the resulting Blender NURBS curves as needed
4. Use `File > Export > SplineMaker Project (.json)` to write data back into SplineMaker's JSON format

The Blender add-on handles coordinate conversion between SplineMaker's project space and Blender's curve space automatically, and preserves point radius and weight values during round-trip import/export.

## Project Notes

- App state and undo history are stored as incremental JSON saves under `user://projects/`
- Closing a project writes a clean export JSON file to `Documents/Splines/` unless you override the export path in the app settings
- OpenXR vendor support is provided through the bundled [`addons/godotopenxrvendors/`](addons/godotopenxrvendors/) plugin
