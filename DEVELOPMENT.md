# SplineMaker Development Plan

## Architecture Decisions

### Renderer: Compatibility (OpenGL) vs Mobile Vulkan
The FEATURES.md specifies Mobile Vulkan, but there are known issues with OpenXR + Vulkan on Quest 3 where apps fail to load. The Compatibility renderer (OpenGL) is the safer choice. **Decision needed:** test both early in Phase 1; if Vulkan works with current Godot 4.6, use it; otherwise fall back to Compatibility.

### NURBS: Custom Implementation Required
Godot's Curve3D is Bezier-only with no NURBS support. The project requires:
- Custom NURBS evaluation in GDScript for realtime mesh preview
- Custom mesh generation (extruded tube with end caps) from evaluated NURBS points
- NURBS math: basis functions, knot vectors, weighted point evaluation

### .blend Export on Quest 3
Blender cannot run on the Quest 3 headset, so the `blender --python` approach is not viable on-device. Options:

**Option A — Write .blend binary directly:** Parse the NurbsCurves.blend template, locate the curve data block, inject NURBS spline data, write the modified file. Complex but fully self-contained on the headset. The .blend format has a public spec (Kaitai Struct) and the template structure is fixed, so we only need to understand one specific data block pattern.

**Option B — Export JSON + desktop converter:** Save spline data as JSON on the device. Provide a Python script that users run on their desktop (`blender NurbsCurves.blend --background --python import_splines.py -- splines.json output.blend`). Simpler to implement but adds a manual step for the user.

**Option C — Hybrid:** Export JSON as the primary data format (also used for auto-save/undo). Build the .blend writer as a later phase, starting with Option B for MVP. This lets us validate the full pipeline early without solving the binary format problem first.

**Recommended: Option C.** JSON export for MVP (proves the pipeline with a desktop conversion step), .blend binary writing as a post-MVP enhancement.

### 3D UI in XR
Godot has no native 3D UI containers. Panels must be built using SubViewport rendered to a texture on a 3D mesh quad, with custom raycasting for interaction.

### Data Storage
JSON files stored in the app's user data directory on Quest 3. Each auto-save/undo step is a separate incrementally-named JSON file. Project structure:
```
user://projects/
  2026-04-07-14-30/
    save_001.json
    save_002.json
    ...
    meta.json  (project name, settings, per-controller action area sizes)
```

---

## Phase 1: Project Scaffolding & XR Foundation

**Goal:** Godot project that runs on Quest 3 in passthrough mode with tracked controllers visible.

### Steps
1. Create Godot 4.6 project with XR configured
   - Create project.godot: renderer = mobile (Vulkan Mobile), ETC2/ASTC compression, foveation level 3 with dynamic foveation
   - Add `android/` to .gitignore (Android build template directory)
   - Install Android build template (manual, in Godot editor: Project → Install Android Build Template)
   - Download and install OpenXR vendor plugin from GodotVR/godot_openxr_vendors GitHub releases (manual, must match Godot 4.6); enable in Project Settings → Plugins
   - Enable Meta Passthrough extension in Project Settings → XR → OpenXR → Extensions → Meta (may need Advanced Settings toggle)
   - Configure export preset for Quest 3 (manual, in Godot editor: XR Mode = OpenXR, Passthrough = Required, Min SDK = 29)
2. Create main scene hierarchy
   - WorldEnvironment node (passthrough configured at runtime via GDScript, not scene properties)
   - XROrigin3D with XRCamera3D
   - Two XRController3D nodes (left hand, right hand) with pose = aim
   - Small sphere mesh (2cm radius) at each controller to confirm tracking
3. Create XR start script (attached to scene root, not an autoload)
   - Initialize OpenXR interface, enable XR on viewport, disable VSync (OpenXR handles timing), enable VRS
   - Configure passthrough at runtime: check XR_ENV_BLEND_MODE_ALPHA_BLEND support, set environment blend mode, transparent viewport bg, Environment.BG_COLOR with alpha 0
   - Handle session lifecycle: session_begun (set refresh rate up to 90Hz, sync physics ticks), session_visible/session_focussed (pause/resume), session_stopping
   - Log all controller input: button_pressed, button_released, input_float_changed, input_vector2_changed signals on both controllers
4. Verify default OpenXR action map provides all required inputs
   - Godot 4.x ships with a default action map that includes trigger, grip, thumbstick, face buttons, and menu — no manual action map setup needed
   - If any input is missing on-device, customize the action map in the editor

### Milestone Test
- [x] App launches on Quest 3 in passthrough mode
- [x] Both controllers are tracked and visible
- [ ] Trigger pressure value (0.0–1.0) logged correctly
- [ ] All button inputs register (grip, joystick, X/A, Y/B, menu)
- [x] Passthrough is clear (no black screen, no visual artifacts)
- [x] Determine renderer: Vulkan Mobile or Compatibility
- [ ] Physics tick rate matches display refresh rate
- [ ] App pauses when headset is removed, resumes when put back on
- [x] WorldEnvironment background is fully transparent (no colored tint)

---

## Phase 2: Project Space & Navigation

**Goal:** 3D axis display with grip-based navigation (translate, rotate, scale).

### Steps
1. Create project space node (Node3D) as parent for all project content
   - XYZ axis visualization: thin coloured lines from -1 to +1 (R=X, G=Y, B=Z)
2. Implement single-grip navigation
   - Track grip press/release per controller
   - While grip held: calculate delta transform from controller motion, apply to project space
   - Translate and rotate project space relative to controller movement
3. Implement dual-grip navigation
   - When both grips held: calculate midpoint, distance, and orientation delta between controllers
   - Apply translation, rotation, and scale to project space
   - Closer controllers = smaller scale, farther = larger
4. Implement view reset
   - Reset project space transform to identity (position, rotation, scale)
   - Wire to menu button on left controller

### Milestone Test
- [x] XYZ axis visible in passthrough, correctly coloured
- [x] Single grip: project space moves and rotates with controller
- [x] Dual grip: project space moves, rotates, and scales
- [ ] Scale responds correctly (closer = smaller)
- [ ] Menu button resets view to default
- [x] Navigation does not modify any data (view-only transform)
- [x] Releasing grips leaves project space in last position

---

## Phase 3: NURBS Math & Mesh Generation

**Goal:** Custom NURBS evaluation and extruded tube mesh generation, testable in-editor.

### Steps
1. Implement NURBS evaluation in GDScript
   - Knot vector generation (uniform, with endpoint clamping option)
   - B-spline basis function evaluation (Cox-de Boor recursion)
   - Weighted point evaluation (rational B-spline / NURBS)
   - Support for variable order U per spline
   - Evaluate curve at N points based on resolution U
2. Implement tube mesh generation
   - Given a polyline of evaluated points + per-point radius (interpolated from control point size values):
     - Generate cross-section circles (N edges, from resolution setting)
     - Orient circles along the curve using Frenet frames or parallel transport (parallel transport preferred to avoid flipping)
     - Connect sequential circles into triangle strips
   - Half-sphere end caps for non-cyclic splines
   - Seamless loop for cyclic splines (no caps)
3. Create a test scene with hardcoded NURBS data
   - Verify mesh looks correct for known spline shapes (straight line, circle, S-curve)
   - Verify end caps render correctly
   - Verify cyclic splines loop without caps

### Milestone Test
- [x] NURBS evaluation produces correct points for known inputs (compare against reference values)
- [x] Tube mesh renders with correct radius at each point
- [x] End caps are half-spheres, visually seamless
- [x] Cyclic splines loop correctly, no end caps
- [ ] Mesh updates when control point data changes
- [x] Performance: single spline with 20 points renders without frame drops on Quest 3

---

## Phase 4: Control Point Visualization & Action Area

**Goal:** Control points visible as cubes, action area sphere on controllers, hover/selection highlighting.

### Steps
1. Implement control point rendering
   - Small cube meshes at each control point position, aligned to project space
   - Thin line (ImmediateMesh or similar) between sequential points
   - Distinct colour for active spline vs neutral colour for others
2. Implement action area sphere
   - Partially transparent sphere at controller tip
   - Joystick X axis resizes (rate proportional to joystick distance)
   - Clamp to 0.01–1.0 range, default 0.1
   - Per-controller size tracking
3. Implement intersection detection
   - Check distance from each control point to action area center
   - Points within action area radius are "hovered"
   - Highlight hovered points: colour change + slight scale-up
   - Lock joystick resize when any point is in the action area
4. Implement hover state transitions
   - On trigger press: hovered points scale back to default, retain highlight colour
   - On trigger release: restore normal state
5. Implement haptic feedback
   - Subtle tap when point first enters action area
   - Light buzz while trigger held during editing

### Milestone Test
- [x] Control point cubes visible, aligned to project space (rotate with space)
- [x] Lines visible between sequential points
- [x] Action area sphere visible at controller tip
- [x] Joystick resizes action area smoothly
- [x] Resize stops at min/max bounds
- [x] Resize disabled when a point is in the action area
- [x] Hovered points highlight with colour and scale
- [x] Trigger press: scale down, colour retained
- [x] Haptic tap on intersection, buzz on edit
- [ ] Active spline colour distinct from neutral

---

## Phase 5: Draw Mode & Smart Point Placement

**Goal:** Draw splines by moving the controller with the trigger held. This is the most complex feature.

### Steps
1. Implement basic draw input
   - On trigger press in Draw mode: begin recording controller tip positions each frame
   - On trigger release: finalize the spline, create undo checkpoint
   - Track trigger pressure per sample for size value
2. Implement smart point placement algorithm
   - **Research phase:** Search for open source curve fitting algorithms (Ramer-Douglas-Peucker for simplification, then least-squares B-spline fitting, or Philip Schneider's curve fitting algorithm adapted for NURBS)
   - **Core requirements:**
     - Input: dense polyline of hand positions + per-sample radius
     - Output: sparse NURBS control points positioned to approximate the path
     - Control points placed outside the drawn path so the resulting NURBS curve passes through/near the path
     - Jitter filtering: smooth the input before fitting
     - Accuracy parameter: controls point density (maps to Curve Accuracy slider)
   - **Fallback approach:** If no suitable open source exists, implement:
     1. Low-pass filter on input positions (exponential moving average)
     2. Ramer-Douglas-Peucker simplification with epsilon tied to accuracy slider
     3. Convert simplified polyline points to NURBS control points (offset outward from curve to account for B-spline smoothing)
3. Implement minimum viable spline check
   - If drawn path length < action area diameter, discard
   - First-time warning popup (auto-dismiss 30s, closeable, grabbable)
4. Implement Order U soft-clamping
   - If point count < 4, set Order U = point count
5. Wire draw mode to mesh generation
   - Realtime mesh preview during drawing (update each frame while trigger held)
   - Final mesh on trigger release
6. Implement Curve Accuracy slider in panel (requires basic panel — can use a temporary debug panel for now)
7. Support simultaneous dual-controller drawing
   - Each controller tracks its own in-progress spline independently

### Milestone Test
- [x] Trigger press begins drawing; controller motion creates a spline
- [x] Drawn spline smoothly follows hand path without capturing jitter
- [x] Control points are sparse and positioned for smooth NURBS result
- [x] Trigger pressure maps to control point size (visible in mesh radius)
- [x] Releasing trigger finalizes spline
- [ ] Curve Accuracy slider changes point density
- [x] Very short draws (shorter than action area) are ignored
- [x] First ignored draw shows warning popup
- [x] Splines with < 4 points have Order U soft-clamped
- [x] Mesh preview updates in realtime while drawing
- [x] Two controllers can draw simultaneously

---

## Phase 6: Data Storage, Auto-Save & Undo/Redo

**Goal:** JSON-based project persistence with file-per-save undo system.

### Steps
1. Define JSON schema for project data
   ```json
   {
     "splines": [
       {
         "order_u": 4,
         "resolution_u": 8,
         "cyclic": false,
         "points": [
           {"x": 0.0, "y": 0.0, "z": 0.0, "size": 0.1, "weight": 1.0},
           ...
         ]
       }
     ],
     "action_area_sizes": {"left": 0.1, "right": 0.1}
   }
   ```
2. Implement project directory management
   - Create project folders under `user://projects/`
   - meta.json for project name, settings
3. Implement auto-save on trigger release
   - Serialize current state to JSON
   - Write as incrementally-named file (save_001.json, save_002.json, ...)
   - Track current position in the undo stack
4. Implement undo/redo
   - Undo: load previous save file, decrement position
   - Redo: load next save file, increment position
   - Suppress while trigger or grip active on either controller
   - Wire to X/A (undo) and Y/B (redo) buttons
   - Discard redo history when a new edit is made after undoing
5. Implement undo step limit
   - When saves exceed the configured limit (default 32), delete oldest files
6. Implement project open/close
   - Load latest save file on open
   - Set default mode: Draw if no splines, Move if splines exist

### Milestone Test
- [x] Drawing a spline creates a save file
- [x] Undo restores previous state (spline disappears or reverts)
- [x] Redo restores undone state
- [ ] Undo/redo suppressed during active trigger/grip
- [x] New edit after undo discards redo history
- [ ] Save files capped at configured limit; oldest cleaned up
- [x] Closing and reopening a project restores all splines
- [x] Action area sizes persist per-controller across sessions
- [ ] Empty project opens in Draw mode; project with splines opens in Move mode

---

## Phase 7: MVP — .blend Export via JSON + Desktop Script

**Goal:** Complete the MVP loop: create project, draw splines, close project, get a .blend file.

### Steps
1. Write Python export script (`export_to_blend.py`)
   - Load NurbsCurves.blend as template
   - Read JSON spline data
   - Create/populate a single curve object with all splines
   - Set per-spline: order_u, resolution_u, use_cyclic_u, use_endpoint_u (for non-cyclic)
   - Set per-point: co (x, y, z, w=1.0), radius (from size value), weight (tilt not needed)
   - Hard-clamp order_u to point count
   - Save as new .blend file
   - Error handling with exit codes
2. Write JSON on project close
   - Export current state as a clean JSON file to the configured export directory
   - Display success or error popup
3. Document the desktop conversion workflow for testers
   - Copy JSON from Quest 3
   - Run: `blender NurbsCurves.blend --background --python export_to_blend.py -- splines.json output.blend`
4. Verify end-to-end in Blender
   - Open exported .blend
   - Confirm geometry nodes generate mesh from the splines
   - Confirm NURBS attributes are correct

### Milestone Test (MVP Acceptance)
- [x] User can create a new project on Quest 3
- [x] User can draw one or more splines in VR
- [x] Closing the project exports JSON to the configured directory
- [x] Running the Python script produces a valid .blend file
- [ ] .blend opens in Blender 4.5+ without errors
- [ ] Splines appear with correct positions, sizes, weights
- [ ] Geometry nodes from template generate mesh from the splines
- [ ] Non-cyclic splines have Endpoint enabled
- [ ] Order U, Resolution U values match what was set in VR
- [x] Export failure shows error popup in VR

---

## Phase 8: UI Panel System

**Goal:** Full control panel with all buttons, mode selection, spline list, and settings.

### Steps
1. Build panel rendering system
   - SubViewport with Control UI elements
   - Render SubViewport texture to a 3D quad mesh
   - Panel anchored in XR world space
2. Implement panel interaction via raycasting
   - Ray from controller tip through panel quad
   - Visual ray line from controller to hit point
   - Trigger click on raycast hit = UI button press
3. Implement panel grab and reposition
   - Spherical collision area around controller
   - Edge highlight on panel intersection
   - Grip while intersecting moves panel (same mechanic as project space)
   - Menu button resets panel position
4. Build panel layout
   - Save/close project button
   - Undo/redo buttons
   - Reset view button
   - Mode selection row (Move, Draw, Extrude, Size, Weight)
   - Curve Accuracy slider (visible in Draw mode only)
   - Spline list with delete buttons, scrollable via joystick Y while pointing
   - Selected spline properties: Order U, Resolution U, Cyclic toggle
   - Empty list text: "add a spline by drawing"
5. Build settings sub-panel (accessible from project list screen)
   - Export folder selector (native OS dialogue)
   - Undo step count
   - Panel side preference (left/right)
   - Preview mesh resolution
6. Build project list panel
   - List of existing projects with rename and delete buttons
   - Create new project button
   - Settings button
   - Delete confirmation dialogue
7. Build popup system (reusable)
   - Auto-dismiss timer (30 seconds)
   - Close button
   - Grabbable/moveable like panels
   - Used for: minimum spline warning, export errors, corruption warnings

### Milestone Test
- [x] Panel renders in 3D space, readable text
- [x] Ray visible from controller to panel hit point
- [x] Buttons respond to trigger click via raycast
- [x] Panel grab and reposition works via grip
- [x] Panel edge highlights on controller intersection
- [ ] Menu button resets panel position
- [ ] Mode selection works; only one active
- [ ] Curve Accuracy slider appears/disappears with Draw mode
- [ ] Spline list scrolls with joystick Y
- [ ] Spline list shows "add a spline by drawing" when empty
- [ ] Selected spline properties editable
- [ ] Delete spline removes it (no confirmation, undo available)
- [ ] Project list: create, open, rename, delete (with confirmation)
- [ ] Settings: all options functional
- [ ] Popups auto-dismiss and can be closed/moved

---

## Phase 9: Remaining Edit Modes

**Goal:** Translate, Move, Extrude, Size, and Weight modes fully functional.

### Steps
1. Implement Translate (default action)
   - Trigger on hovered point(s): move with controller
   - Save position on trigger release
2. Implement Move mode
   - Detect spline intersection (any point of the spline in action area)
   - Trigger: translate and rotate entire spline with controller
   - Joystick: scale spline points (centered at controller), scale size values proportionally
   - Selecting a spline in Move mode updates panel list selection
3. Implement Extrude mode
   - Identify start/end points (valid) vs mid-spline points (non-valid)
   - Trigger on valid point: create new point, move with controller
   - All valid points in action area extrude simultaneously
   - Non-valid points: fall back to translate
4. Implement Size mode
   - Joystick adjusts size value of hovered points
   - Trigger: translate (joystick only changes size, not group scale)
5. Implement Weight mode
   - Joystick adjusts weight of hovered points (0.001–10.0)
   - Trigger: translate (joystick only changes weight)
6. Implement control point deletion
   - Y/B while trigger held with point in active area: remove point
   - Triggers autosave/undo stage

### Milestone Test
- [ ] Translate: point moves with controller, saves on release
- [ ] Move: entire spline translates/rotates
- [ ] Move: joystick scales spline + size values proportionally
- [ ] Move: selects spline in panel list
- [ ] Extrude: new point created from valid endpoint
- [ ] Extrude: multiple endpoints extrude simultaneously
- [ ] Extrude: mid-spline points fall back to translate
- [ ] Size: joystick changes size, mesh updates in realtime
- [ ] Size: trigger translates point, joystick still changes size
- [ ] Weight: joystick changes weight within bounds, mesh updates
- [ ] Weight: trigger translates point, joystick still changes weight
- [ ] Delete: Y/B + trigger removes point, undo restores it
- [ ] All edits trigger autosave on trigger release

---

## Phase 10: Data Integrity & Polish

**Goal:** Corruption detection, remaining edge cases, and overall quality.

### Steps
1. Implement corruption detection
   - Validate JSON on load (schema check, reasonable value ranges)
   - Keep previous version on project open
   - Corruption on open: warning with rollback option
   - Corruption on autosave: warning with rollback to previous undo state
2. Implement .blend binary writer (post-MVP enhancement)
   - Parse NurbsCurves.blend template structure
   - Locate curve data block
   - Write NURBS spline data directly into .blend
   - Eliminate desktop conversion step
3. Polish and edge cases
   - Redo history discarded on new edit after undo
   - Spline deletion: handle last point (delete entire spline?)
   - Order U soft-clamp: update when points are added/removed
   - Panel side preference applied on project open
   - Export directory creation if it doesn't exist
   - Native OS dialogues verified on Quest 3 platform

### Milestone Test
- [ ] Corrupted JSON detected on open; rollback offered and works
- [ ] Corrupted JSON detected on save; rollback offered and works
- [ ] Previous version retained correctly
- [ ] (Post-MVP) .blend written directly on device without desktop step
- [ ] All edge cases handled gracefully (empty splines, single point, etc.)

---

## Summary: Phase Dependencies

```
Phase 1: XR Foundation
  └─ Phase 2: Project Space & Navigation
      └─ Phase 3: NURBS Math & Mesh Generation
          ├─ Phase 4: Control Points & Action Area
          │   └─ Phase 5: Draw Mode & Smart Placement
          │       └─ Phase 6: Data Storage & Undo
          │           └─ Phase 7: MVP (.blend Export) ← USER TESTING
          │               ├─ Phase 8: UI Panel System
          │               ├─ Phase 9: Remaining Edit Modes
          │               └─ Phase 10: Data Integrity & Polish
          └─ (Phase 3 also feeds into Phase 9 for mesh updates)
```

Phases 8, 9, and 10 can be developed in parallel after the MVP milestone.
