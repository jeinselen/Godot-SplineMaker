Build an XR utility for drawing and editing splines using Godot 4.6, OpenXR, and Mobile Vulkan.

Why Godot:
- Open source and free to use
- Text-based scene files for agentic coding

Target Platform:
- Meta Quest 3 with passthrough

User Experience:
- Open the app on a VR headset
	- Passthrough mode, no virtual environment
	- Simple panel with project list (choose existing project or create new project) and settings button to open settings sub-panel
		- Each project entry has a rename button (opens platform text entry) and a delete button (opens a confirmation dialogue before deleting)
		- Settings sub-panel should include a folder selector for the file output location (ideally the default should be the user's documents directory, if not, on first launch the user should be prompted to choose an output location for exported .blend files) and any available global performance adjustments (such as setting the resolution of preview meshes)
		- Settings should include undo step count (default 32)
		- Settings should include control panel side preference (left or right)
- Project is opened (either existing or new)
	- New projects should be automatically named with the date and time (YYYY-MM-DD-HH-MM)
	- Visual X, Y, Z axis for the project space (1 unit = 1 meter, the axis visuals can extend to just the -1 through +1 range in all three directions)
	- Panel of controls
		- Buttons to save and close project, undo, redo, and reset view (reset position of project space in XR space)
		- Mode selection (options listed in a row, just one active at a time, falling back to a default Translate interaction as needed):
			- Move (spline edit mode, allows for translation of splines)
			- Draw (create new spline, generating control points automatically as the controller moves through space)
			- Extrude (extend existing splines from start or end points, one point at a time)
			- Size (set the size value of a control point and the resulting diameter of the generated mesh)
			- Weight (set the weight of a control point)
		- Spline list (with delete buttons once splines are added)
			- Clicking a spline list entry selects that spline; the latest created spline or manually selected spline remains active (no deselect)
			- Selected spline should have the following available properties:
				- Order U (default to 4)
				- Resolution U (default to 8, slightly lower than Blender's default of 12, but should be better for performance in VR)
				- Cyclic toggle for closed/open spline loops
	- No confirmation is needed when deleting a spline, as the undo system is available while in a project
- Splines are drawn, extruded, and edited by the user
	- Data is continually auto-saved, so there shouldn't be any need to manually save the data
- Project is closed
	- While the spline data is auto-saved, the Blender file export should only occur when the project is closed to avoid constant processing
	- Blender files should be exported not to the app location but to the user's Documents/Splines/ directory (it may be necessary to choose a custom location in the app settings, depends on the Meta Quest 3 platform)

Control Panel:
- The control panel should be anchored in world (XR) space, positioned off to the left or right side based on the user's preference (selectable in settings)
- The panel can be grabbed and repositioned by intersecting the controller with the panel and using the grip (grab) button; this uses the same mechanic as moving the project space, but moves the panel instead whenever the controller's general area (a spherical falloff containing the controller, not visible) intersects with the panel
- The panel edge should highlight when the controller intersection occurs, giving the user visual feedback; no other visual change is necessary while moving

Controls:
- Ambidextrous usage (no primary/secondary controllers, both left and right operate the same)
- For panels:
	- Point with controllers from any distance, a line should be drawn from the controller to the point on the panel it's pointing at
- For project space (anywhere in the project experience, controller intersection or pointing doesn't matter, this is just for the grip buttons):
	- Move and rotate project space while holding the grip on one controller and moving or rotating the controller
	- Move, rotate, and scale the project space while holding the grips on both controllers at once and moving them (closer together = smaller project scale)
	- Project translation, rotation, and scale are view-exclusive, and should not impact project data, should not be saved with the project, and should be reset every time a project is opened (it must only change the view of the project coordinate system, never changing the coordinates themselves)
- Button mappings:
	- Trigger: primary action (draw, extrude, translate, interact with panels)
	- Grip: grab and move project space or control panel
	- X or A: undo (in addition to the undo button on the control panel)
	- Y or B: redo (in addition to the redo button on the control panel)
	- Y or B while trigger held with point in active area: delete control point
	- Joystick: mode-dependent (resize action area, adjust size/weight values, scale splines)
- Translate action (default action regardless of mode, when the trigger isn't used by the Draw mode):
	- Controllers should display a partially transparent sphere at the tip of the controller (action area)
	- Action area size should be adjustable using the left and right (X axis) of the joystick on that controller (pressing left = grow smaller, pressing right = grow larger, with the distance of the joystick determining how quickly the sphere will shrink or expand, stopping at a minimum of 0.01 unit (0.01m), and a maximum of 1 unit (1m), and starting with a default of 0.1 units)
	- Action area size should NOT be adjustable with the joystick when a spline or point is intersecting with it, allowing for other modes to operate as expected during editing
	- Action area should highlight when a valid control point is within the diameter of the sphere (start or end of any spline, can use spherical collision, intersection, point falloff, or whatever method is most native and efficient in Godot)
	- Any spline (in Move mode) or control point(s) (in Size, Weight, and special Extrude cases) that intersect with the action area of a controller should move with the controller when the trigger is depressed, and be saved in the new location when the trigger is released
- Move:
	- Already detailed in the translate interaction above, this mode is the only one that operates in the spline domain; when any spline intersects with the action area of a controller, it can be translated (moved and rotated) or scaled (using the joystick)
	- Joystick -X and -Y should scale the spline points down, centered at the controller location, +X and +Y joystick motion should scale the spline points up. Additionally, control point size values should be scaled down or up at the same rate, so the resulting mesh proportions are retained
	- Moving a spline also selects that spline's entry in the panel list
- Draw:
	- Same controller visual and action area as the Translate action (partially transparent sphere representing the maximum draw size)
	- Joystick left/right adjusts the maximum draw size (same controls and range as the action area: min 0.01, max 1 unit, default 0.1 units)
	- Pull trigger to draw spline using either controller (controllers should operate independently, so two different splines can be created at the same time if desired)
	- The drawn spline should smoothly follow controller path, strategically placing control points outside of that path to generate a NURBS spline that's smooth and not too dense (for example, if the user draws a circle, the spline control points should be placed in positions, such as a larger octagon, so that the resulting spline matches the user's drawn path)
	- The trigger value should be used to drive the size value of the spline control points; mapping button pressure value to a 0.01 to the current maximum draw size floating point value range
	- Cyclic always defaults to off when drawing a new spline
	- Minimum viable spline length must match the size of the drawing tool (action area); anything shorter should be ignored
	- The first time a spline is ignored in a new project, a warning popup should appear at the location of the failed spline with a brief explanation so the user understands why; the popup auto-dismisses after 30 seconds or can be closed early via a close button; it behaves like all other UI panels (pointable, closeable, grabbable and moveable)
	- Splines are expected to have fairly sparse points for smooth results; if fewer than 4 control points are generated, the Order U should be soft-clamped to the number of points until more are added; Order U is only hard-clamped during .blend export, where it must be no more than the total number of control points
- Extrude:
	- Same controller visual and action area as the Translate action
	- When a valid control point is active within the action area, pulling the trigger and moving the controller will extrude a new control point
	- If a non-valid control point is hovered (any point that's not a start or end point of a spline), the standard translate action should be used instead (click and drag with the controller trigger to translate the control point)
- Size:
	- Same controller visual and action area as the Translate action
	- Any control point(s) that intersect with the action area of a controller should increase or decrease in size based on joystick input; -X or -Y should decrease the size value of the active control point(s), +X or +Y should increase the size value
	- If the trigger button is depressed, the control point should be moved (translation is a default action if the current mode doesn't override the behaviour, and in this case, pressing the trigger should move the point but the joystick should not attempt to scale groups of points; the joystick should only change the size value)
- Weight:
	- Same controller visual and action area as the Translate action
	- Any control point(s) that intersect with the action area of a controller should increase or decrease the spline curvature weight based on joystick input; -X or -Y should decrease the size value of the active control point(s), +X or +Y should increase the size value, with a minimum of 0.001 and maximum of 10.0
	- If the trigger button is depressed, the control point should be moved (translation is a default action if the current mode doesn't override the behaviour, and in this case, pressing the trigger should move the point but the joystick should not attempt to scale groups of points; the joystick should only change the weight value)

Control Point Visualization:
- Control points are displayed as small cubes aligned to the project space (not XR space; if the user rotates the project space, the cubes rotate with it)
- A thin line is drawn between sequential control points in each spline so the point order is visible even when points are spread apart
- Points highlight when inside the active area of a controller: colour change and a slight scale-up to indicate hovering
- When the trigger is pulled on a hovered point, the point scales back down to default size but retains the highlighted colour until the trigger is released
- The active spline (as selected in the panel list) should have a distinct colour; all other splines use a neutral colour
- A spline being moved in Move mode also uses the active colour (and selects the spline in the panel list)

Haptic Feedback:
- A very subtle tap haptic when a panel, spline (Move mode only), or control point (all other modes) first intersects with the active area
- A light buzz while actively editing or moving elements (trigger held during translate, draw, extrude, or value adjustment)

Spline data:
- Data should be stored internally in the simplest way possible, ideally just spline index (no need for naming splines), order U, and resolution U values, and for each control point in that spline, project space XYZ coordinates, the size value, and the weight value
- Edits should be saved automatically when the edit is "applied" (when the trigger releases after drawing, when the trigger is released after extruding, translating, size, or weight)

Undo/Redo:
- Undo stages match autosave events (any change committed on trigger release)
- Implementation: each autosave writes a new incrementally-named file; undo steps back through previous autosave files, redo steps forward
- Maximum undo steps configurable in settings (default 32); older files beyond this limit are cleaned up
- Accessible via X/A buttons (undo) and Y/B buttons (redo) on either controller, as well as undo/redo buttons on the control panel

Dynamic spline mesh:
- Splines should be visualised as an extruded mesh with half-sphere end caps, ideally including while drawing/editing operations are underway
- Spline visual should have adjustable resolution, defaulting to 8 edges

Output .blend file:
- Exported .blend file should be compatible with Blender 4.5 or greater (the template file targets Blender 5.1, which is fine)
- All splines from the project should be in a single Blender curve object, with attributes correctly set for native use in Blender, and Endpoint enabled for each of the non-cyclic splines in the curve object
- Reference NurbsCurves.blend as the template (it includes geometry nodes for generating the mesh in Blender, only the splines themselves need to be saved in the file, no mesh)
- If .blend export fails, a warning popup should appear with relevant error codes; auto-dismisses after 30 seconds or can be closed early via close button; behaves like all other UI panels

Data Integrity:
- The previous version of a project file should be kept when opening a project
- If corruption is detected when opening a project, the user receives a warning and the option to roll back to the previous version
- If corruption is detected during an autosave event, the user receives a warning and the option to roll back to the previous undo state

---

# Validation Criteria

## App Launch / Project List
- [ ] App opens in passthrough mode with no virtual environment
- [ ] Panel displays list of existing projects and option to create new
- [ ] New projects are named with date/time format YYYY-MM-DD-HH-MM
- [ ] Each project has a rename button that opens platform text entry
- [ ] Each project has a delete button that opens a confirmation dialogue
- [ ] Settings sub-panel opens from settings button
- [ ] Settings includes folder selector for .blend export location
- [ ] Settings includes undo step count (default 32)
- [ ] Settings includes control panel side preference (left or right)
- [ ] First launch prompts for export location if default (Documents) is unavailable

## Control Panel
- [ ] Panel anchored in world (XR) space
- [ ] Initial position offset to left or right per settings preference
- [ ] Panel edge highlights when controller area intersects it
- [ ] Grip button while intersecting grabs and repositions the panel
- [ ] Panel grab uses same mechanic as project space movement
- [ ] Panel remains in repositioned location until manually moved again

## Project Space
- [ ] Visual X, Y, Z axis displayed from -1 to +1 range
- [ ] 1 unit = 1 meter scale is correct
- [ ] Panel displays save/close, undo, redo, and reset view buttons
- [ ] Mode selection shows all modes in a row; only one active at a time
- [ ] Default mode falls back to Translate interaction
- [ ] Spline list displays with delete buttons for each spline (no confirmation needed; undo available)
- [ ] Clicking a spline list entry selects it; latest created or manually selected spline remains active
- [ ] Selected spline shows Order U (default 4), Resolution U (default 8), and Cyclic toggle

## Grip Controls (Project Space Navigation)
- [ ] Single grip: move and rotate project space with controller motion
- [ ] Dual grip: move, rotate, and scale (closer = smaller)
- [ ] Grip on panel area moves panel instead of project space
- [ ] Navigation transforms are view-only; project data coordinates unchanged
- [ ] Navigation resets when a project is opened
- [ ] Navigation state is not saved with project data

## Control Point Visualization
- [ ] Points displayed as small cubes aligned to project space (rotate with project, not XR space)
- [ ] Thin line drawn between sequential points in each spline
- [ ] Points highlight (colour + slight scale-up) when inside a controller's active area
- [ ] On trigger pull, hovered points scale back to default but retain highlight colour until trigger release
- [ ] Active spline (selected in list) uses a distinct colour
- [ ] Spline being moved in Move mode uses active colour and selects entry in panel list
- [ ] Non-active splines use a neutral colour

## Haptic Feedback
- [ ] Subtle tap when panel first intersects controller area
- [ ] Subtle tap when spline (Move mode) or control point (other modes) first intersects active area
- [ ] Light buzz while actively editing or moving elements (trigger held)

## Action Area (Shared by all modes)
- [ ] Partially transparent sphere displayed at controller tip
- [ ] Joystick left/right resizes sphere (left = smaller, right = larger)
- [ ] Minimum size: 0.01 units, maximum: 1 unit, default: 0.1 units
- [ ] Resize rate scales with joystick distance from center
- [ ] Joystick resizing disabled when a spline or point intersects action area
- [ ] Sphere highlights when a valid control point is within its diameter

## Button Mappings
- [ ] Trigger: primary action (draw, extrude, translate, panel interaction)
- [ ] Grip: grab/move project space or control panel
- [ ] X or A: undo
- [ ] Y or B: redo
- [ ] Y or B while trigger held with point in active area: delete control point
- [ ] Joystick: mode-dependent behaviour

## Translate (Default Action)
- [ ] Intersecting control point(s) move with controller while trigger held
- [ ] Point position saved on trigger release

## Move Mode
- [ ] Intersecting spline (not just points) can be grabbed and translated/rotated
- [ ] Joystick -X/-Y scales spline points down (centered at controller); +X/+Y scales up
- [ ] Control point size values scale proportionally with spline scaling
- [ ] Moving a spline selects it in the panel list

## Draw Mode
- [ ] Same action area sphere displayed (represents maximum draw size)
- [ ] Joystick adjusts maximum draw size (same range as action area: 0.01-1.0, default 0.1)
- [ ] Pulling trigger begins drawing a new spline
- [ ] Both controllers can draw independently and simultaneously
- [ ] Spline smoothly follows controller path
- [ ] Control points placed strategically outside drawn path for smooth NURBS result
- [ ] Trigger pressure maps to control point size value (0.01 to current max draw size)
- [ ] New drawn splines default to non-cyclic
- [ ] Splines shorter than action area size are ignored
- [ ] First ignored spline in a new project shows a warning popup at the location
- [ ] Warning popup auto-dismisses after 30 seconds or can be closed manually
- [ ] Warning popup is grabbable and moveable like all panels
- [ ] Splines with fewer than 4 points: Order U soft-clamped to point count
- [ ] Order U only hard-clamped (to point count) during .blend export

## Extrude Mode
- [ ] Valid control point (start/end of spline) highlighted in action area
- [ ] Pulling trigger on valid point extrudes a new control point
- [ ] Moving controller while trigger held positions the new point
- [ ] Non-valid points (mid-spline) fall back to translate behavior

## Size Mode
- [ ] Joystick -X/-Y decreases size of intersecting control point(s)
- [ ] Joystick +X/+Y increases size of intersecting control point(s)
- [ ] Trigger held: translates point (joystick changes size only, not group scale)

## Weight Mode
- [ ] Joystick -X/-Y decreases weight of intersecting control point(s)
- [ ] Joystick +X/+Y increases weight of intersecting control point(s)
- [ ] Weight range: minimum 0.001, maximum 10.0
- [ ] Trigger held: translates point (joystick changes weight only)

## Deleting Control Points
- [ ] Y or B button while trigger held and point in active area removes the point
- [ ] Deletion triggers an autosave/undo stage
- [ ] Deleted point can be restored via undo

## Undo/Redo
- [ ] Undo stages match autosave events (trigger release commits)
- [ ] Each autosave writes a new incrementally-named file
- [ ] Undo steps back through previous files; redo steps forward
- [ ] Maximum undo steps respects settings value (default 32)
- [ ] Older files beyond limit are cleaned up
- [ ] X/A buttons trigger undo on either controller
- [ ] Y/B buttons trigger redo on either controller
- [ ] Panel undo/redo buttons work via point-and-trigger

## Spline Data & Auto-Save
- [ ] Data stored as: spline index, order U, resolution U, and per-point XYZ + size + weight
- [ ] Auto-save triggers on trigger release (after draw, extrude, translate, size, weight, or delete)
- [ ] Data persists correctly when reopening a project

## Dynamic Spline Mesh Preview
- [ ] Splines visualized as extruded mesh with half-sphere end caps
- [ ] Preview updates during drawing/editing operations
- [ ] Mesh resolution adjustable, defaulting to 8 edges

## .blend Export
- [ ] Export triggers only on project close (not during editing)
- [ ] File written to Documents/Splines/ (or user-configured location)
- [ ] File opens correctly in Blender 4.5+
- [ ] All splines in a single Blender curve object
- [ ] NURBS attributes (order, resolution, weights) correctly set
- [ ] Order U hard-clamped to point count per spline on export
- [ ] Endpoint enabled for non-cyclic splines
- [ ] Geometry nodes from NurbsCurves.blend template generate mesh correctly
- [ ] Export failure shows warning popup with error codes
- [ ] Failure popup auto-dismisses after 30 seconds or closeable manually

## Data Integrity
- [ ] Previous project version kept when project is opened
- [ ] Corruption on open: warning shown with option to roll back to previous version
- [ ] Corruption on autosave: warning shown with option to roll back to previous undo state
