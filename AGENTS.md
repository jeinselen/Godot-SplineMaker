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
