#!/usr/bin/env python3
"""
Export SplineMaker JSON spline data into a .blend file using the NurbsCurve template.

Usage (run from the command line with Blender in background mode):
    blender NurbsCurve.blend --background --python export_to_blend.py -- input.json output.blend

Arguments after "--":
    input.json   Path to the SplineMaker JSON export file
    output.blend Path for the output .blend file

Exit codes:
    0  Success
    1  Missing or invalid arguments
    2  JSON file not found or unreadable
    3  JSON parse error or invalid schema
    4  Blender data error (could not create/modify curve object)
    5  File write error
"""

import sys
import json
import os


def main():
    # Parse arguments after "--"
    try:
        sep = sys.argv.index("--")
    except ValueError:
        print("ERROR: Expected '--' separator followed by input.json and output.blend")
        print(__doc__)
        sys.exit(1)

    args = sys.argv[sep + 1:]
    if len(args) < 2:
        print("ERROR: Expected 2 arguments after '--': input.json output.blend")
        print(f"Got: {args}")
        sys.exit(1)

    input_path = args[0]
    output_path = args[1]

    # --- Read JSON ---
    if not os.path.isfile(input_path):
        print(f"ERROR: Input file not found: {input_path}")
        sys.exit(2)

    try:
        with open(input_path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        print(f"ERROR: JSON parse error: {e}")
        sys.exit(3)
    except OSError as e:
        print(f"ERROR: Could not read input file: {e}")
        sys.exit(2)

    # --- Validate JSON schema ---
    if not isinstance(data, dict):
        print("ERROR: JSON root must be an object")
        sys.exit(3)

    splines = data.get("splines", [])
    if not isinstance(splines, list):
        print("ERROR: 'splines' must be an array")
        sys.exit(3)

    if len(splines) == 0:
        print("WARNING: No splines in JSON file, writing empty curve object")

    # --- Import Blender modules (only available inside Blender) ---
    try:
        import bpy
    except ImportError:
        print("ERROR: This script must be run inside Blender:")
        print("  blender NurbsCurve.blend --background --python export_to_blend.py -- input.json output.blend")
        sys.exit(1)

    # --- Build curve data ---
    try:
        # Remove any existing curve objects from the template to start clean
        for obj in list(bpy.data.objects):
            if obj.type == "CURVE":
                bpy.data.objects.remove(obj, do_unlink=True)

        # Remove orphan curve data blocks
        for curve in list(bpy.data.curves):
            if curve.users == 0:
                bpy.data.curves.remove(curve)

        # Create a new curve data block
        curve_data = bpy.data.curves.new(name="SplineMakerCurves", type="CURVE")
        curve_data.dimensions = "3D"

        for i, spline_json in enumerate(splines):
            if not isinstance(spline_json, dict):
                print(f"WARNING: Skipping spline {i}: not an object")
                continue

            points_json = spline_json.get("points", [])
            if not isinstance(points_json, list) or len(points_json) < 2:
                print(f"WARNING: Skipping spline {i}: needs at least 2 points, got {len(points_json) if isinstance(points_json, list) else 0}")
                continue

            order_u = int(spline_json.get("order_u", 4))
            resolution_u = int(spline_json.get("resolution_u", 8))
            cyclic = bool(spline_json.get("cyclic", False))

            # Hard-clamp order_u to point count (required for valid NURBS in Blender)
            point_count = len(points_json)
            order_u = min(order_u, point_count)
            order_u = max(order_u, 2)  # Blender minimum order is 2

            # Create NURBS spline
            spline = curve_data.splines.new("NURBS")

            # NURBS splines start with 1 point; add the rest
            spline.points.add(point_count - 1)

            for j, pt in enumerate(points_json):
                x = float(pt.get("x", 0.0))
                y = float(pt.get("y", 0.0))
                z = float(pt.get("z", 0.0))
                w = float(pt.get("weight", 1.0))
                size = float(pt.get("size", 0.1))

                # Blender NURBS points use (x, y, z, w) where w is the homogeneous weight
                spline.points[j].co = (x, y, z, w)
                spline.points[j].radius = size
                # Tilt is not used by SplineMaker; leave at 0

            spline.order_u = order_u
            spline.resolution_u = resolution_u
            spline.use_cyclic_u = cyclic

            # Enable endpoint clamping for non-cyclic splines
            # This makes the curve pass through the first and last control points
            if not cyclic:
                spline.use_endpoint_u = True

            print(f"  Spline {i}: {point_count} points, order={order_u}, res={resolution_u}, cyclic={cyclic}")

        # Create object and link to scene
        curve_obj = bpy.data.objects.new("SplineMakerCurves", curve_data)

        # Link to the active collection (or scene collection as fallback)
        collection = bpy.context.view_layer.active_layer_collection.collection
        collection.objects.link(curve_obj)

        print(f"Created curve object with {len(curve_data.splines)} spline(s)")

    except Exception as e:
        print(f"ERROR: Failed to create curve data: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(4)

    # --- Save .blend file ---
    try:
        # Ensure output directory exists
        output_dir = os.path.dirname(os.path.abspath(output_path))
        os.makedirs(output_dir, exist_ok=True)

        bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(output_path))
        print(f"Saved: {output_path}")

    except Exception as e:
        print(f"ERROR: Failed to save .blend file: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(5)

    print("Export complete.")
    sys.exit(0)


if __name__ == "__main__":
    main()
