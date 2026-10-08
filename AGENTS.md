# AGENTS.md

Notes for agents working in this repo. **Read this first**; add hard-won details here instead of re-discovering them.

## Project
- VR spline drawing/editing app for Meta Quest 3, Godot **4.7.2**. Main scene: `scenes/main.tscn`.
- Scripts in `scripts/`. Key file: `scripts/interaction.gd` (hover, trigger, delete, stylus routing — largest, most central).

## Syntax-checking GDScript (no HMD needed)
Godot binary: `/Applications/Godot.app/Contents/MacOS/Godot`

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless --check-only --script scripts/<file>.gd --path .
```

- Exit `0` = script parsed OK. Real parse errors print as `SCRIPT ERROR` / `Parse Error`.
- **Ignore the OpenXR noise** — headless has no XR runtime, so it always logs `Failed to enumerate ... extension properties`, `OpenXR was requested but failed to start`, `HMD was not detected`, and a trailing `Check logged errors in debugger for more details.` These are environmental, not code problems. Filter with `grep -i error | grep -vi "openxr\|runtime\|extension\|hmd"`.
- Cannot run/preview the app or its XR interactions headless — only static parse checks.

## Architecture notes
- **Hover highlighting** has two sources of truth that must stay in sync: `interaction.gd` `_left/right_hover_set` (authoritative, re-derived every frame from controller position) and `SplineNode._hovered_points` (index-keyed render cache). Any structural edit that shifts point indices (delete, merge) must call `interaction.clear_hover_sets()` — the single complete reset for both sides — then let next frame's `_update_hover` re-derive. Never persist index-keyed state across index-shifting mutations.
- `_hover_locked(hand)` pauses hover detection while a hand is mid-edit (draw/grip/extrude/stylus-drag) so highlights don't bleed onto passed-over points.

## Data model
- `SplineData` (Resource) = raw geometry: `points`/`sizes`/`weights` as **Packed arrays**. Packed arrays have no built-in insert/remove — use the `_insert_*`/`_remove_*` helpers in `spline_data.gd`. `remove_point`/`insert_point`/`merge_adjacent_duplicates` all shift indices.
- `SplineNode` (Node3D) wraps one `SplineData` + rendering (tube mesh, control-point cubes, connecting lines) + symmetry transforms. Mutating `data` requires `mark_dirty()`; the actual rebuild happens next frame in `_process`.
- Conventions: files lowercase (`spline_node.gd`), classes PascalCase via `class_name` (`SplineNode`). Managers reached by scene-unique names (`%ProjectManager`, `%AppManager`), **not** autoloads. `project_manager.gd` owns serialized state + `autosave()`; call it after edits.

## XR target
- OpenXR, Meta Quest 3 / AndroidXR. Passthrough enabled (Meta + HTC), foveation on, additive blend mode. Addons: `godotopenxrvendors` (XR export), `godot_ai`. MX Ink stylus support is Quest-3-only (see memory).

## Steam Frame (SteamOS arm64, on-device development)
- Godot binary: `~/Applications/Godot_v4.7.2-stable_linux.arm64` (official build). **Don't use Flatpak Godot to run the app.** Its sandbox (PID namespace) breaks SteamVR's OpenXR client, so XR never initializes. The Flatpak is fine for editing only.
- Run on device: F5 from the editor launches natively through SteamVR (`SteamVR/OpenXR 2.18.2`). No export or deploy step.
- Verified 2026-10-08: OpenXR initializes, supported blend modes `[0, 2]` → alpha-blend passthrough works, refresh rate **72 Hz only**, render target 1728×1728/eye, all actions bound via `/interaction_profiles/valve/frame_controller_valve` in `openxr_action_map.tres`.
- Harmless log noise: `Property not found: 'xr/openxr/extensions/hand_tracking'` (vendors plugin 4.3.0 on 4.7), one failed `xrCreateInstance` before the successful one, and "Gamescope WSI Layer Error … Hooking has failed" (desktop mirror window; may show an OK/Cancel dialog, so press OK).
- Export: `SteamFrame` preset (Linux, arm64, ETC2/ASTC) → `linux/SplineMaker.arm64`. Needs 4.7.2 export templates installed (Editor → Manage Export Templates).
- Steam shortcut: run `./linux-install.command` (no manual "Add to Steam" needed). It installs `~/.local/share/applications/splinemaker.desktop`, then creates/updates the entry in `userdata/*/config/shortcuts.vdf` and copies library art into `grid/<appid>…`. Hard-won details:
  - **`OpenVR=1` ("Include in VR Library") is required.** Without it Steam launches the app as a flat game. OpenXR still starts, but the session stalls at `XR_SESSION_STATE_VISIBLE` and never reaches `FOCUSED` (see `~/.local/share/Steam/logs/xrclient_SplineMaker.txt`). Manual equivalent: Properties → Shortcut → "Include in VR Library".
  - **Don't edit `shortcuts.vdf` directly.** Steam keeps shortcuts in memory and overwrites the file. On SteamOS Steam is the `steam.service` user unit (`Restart=always`), and stopping it ends the whole session, which also kills the script. Instead the script calls Steam's JS API (`SteamClient.Apps.AddShortcut/SetShortcutName/SetShortcutIcon/SetShortcutIsVR/SetCustomArtworkForApp`) in the `SharedJSContext` target on Steam's CEF debug port `127.0.0.1:8080` (Steam on the Frame runs with `--remote-debugging-port=8080`). Changes apply live, and Steam saves the vdf and grid files itself. `AddShortcut` ignores its name argument, so follow it with `SetShortcutName`. Artwork types: 0 portrait, 1 hero, 2 logo, 3 wide capsule, 4 icon.
  - Shortcut appids are random. Removing and re-adding a shortcut gives it a new appid, which orphans any grid art copied by hand.
  - Steam rejects the 432px RGB `icon.png` ("load icon … failed: invalid format" in `logs/console_log.txt`) but accepts the 256px RGBA `linux/SplineMaker.png` the script generates (verified 2026-10-08).
  - Double-clicking a `.command` in Dolphin runs it with no terminal, so the script reopens itself in `konsole`.
- Exports default to `~/Documents/Splines/` on Linux (`OS.SYSTEM_DIR_DOCUMENTS`); user data in `~/.local/share/godot/app_userdata/SplineMaker/`.
