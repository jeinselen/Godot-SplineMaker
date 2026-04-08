# SplineMaker

VR spline drawing and editing tool for Meta Quest 3.

## Tech Stack
- Godot 4.6 with GDScript
- OpenXR + Mobile Vulkan
- Target: Meta Quest 3 with passthrough

## Project Structure
- `FEATURES.md` — Full design spec with feature descriptions and validation criteria
- `NurbsCurves.blend` — Blender template for .blend export (geometry nodes for mesh generation; only spline data needs to be written)

## Conventions
- GDScript style: follow Godot's official GDScript style guide (snake_case for variables/functions, PascalCase for classes/nodes)
- 1 unit = 1 meter in project space
- Ambidextrous controls: both controllers operate identically
- All spline editing auto-saves on trigger release; .blend export only on project close
- Undo system is file-based: each autosave is an incrementally-named file, undo/redo steps through them

## Key Constraints
- Mobile Vulkan performance: keep draw calls and mesh complexity low
- Default spline resolution U = 8 (lower than Blender's 12 for VR performance)
- Export .blend files to user's Documents/Splines/ directory, not app directory
- .blend output must be compatible with Blender 4.5+
- Order U soft-clamped in-app (to point count), hard-clamped only on .blend export
