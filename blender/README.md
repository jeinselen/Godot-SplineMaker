# Spline Maker I/O for Blender 5.1

This directory contains a Blender extension package that imports SplineMaker project JSON files as native Blender NURBS splines and exports Blender NURBS splines back into the SplineMaker JSON format.

## Files

- `blender_manifest.toml` - Blender 5.1 extension manifest
- `__init__.py` - import/export operators and File menu registration
- `io_core.py` - shared JSON parsing, validation, metadata storage, and NURBS conversion helpers

## Install

1. Zip the contents of this directory, or run Blender's extension build command from this folder:

```sh
blender --command extension build --source-dir /path/to/Godot-SplineMaker/blender
```

2. In Blender 5.1, open `Edit > Preferences > Extensions`.
3. Use `Install from Disk`, then select the built zip package.

## Import workflow

1. Open the template `.blend` file in Blender.
2. Use `File > Import > SplineMaker Project (.json)`.
3. Select one or more `.json` files. Each file is imported as a new curve object named from the source filename without its extension.

## Export workflow

1. Select or activate the curve object you want to export.
2. Use `File > Export > SplineMaker Project (.json)`.
3. If one object is exported, the chosen filepath is used directly. If multiple objects are exported, one `.json` file is written per object into the chosen directory.

## Notes

- Coordinates are swizzled between SplineMaker's Y-up space and Blender's Z-up space during import and export, and Blender's Y axis is sign-flipped as part of that conversion.
- Imported spline point radius maps to SplineMaker `size`.
- Imported NURBS homogeneous weight maps to SplineMaker `weight`.
- Non-NURBS splines are skipped on export with a warning.
- Order U is hard-clamped on import/export to match Blender and SplineMaker requirements.
- Exported project metadata always includes the default JSON version, curve smoothness, and left/right action area sizes.
- `resolution_u` is accepted on import for compatibility with older files but is no longer written on export.
