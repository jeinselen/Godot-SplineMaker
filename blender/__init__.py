from __future__ import annotations

from pathlib import Path

import bpy
from bpy.props import (
    BoolProperty,
    CollectionProperty,
    EnumProperty,
    StringProperty,
)
from bpy.types import Operator
from bpy_extras.io_utils import ExportHelper, ImportHelper

from .io_core import (
    DEFAULT_ACTION_AREA_SIZE,
    DEFAULT_CURVE_SMOOTHNESS,
    DEFAULT_OBJECT_NAME,
    DEFAULT_PROJECT_VERSION,
    build_curve_object_from_project,
    load_project,
    project_from_curve_objects,
    resolve_export_objects,
    save_project,
    store_project_metadata,
    suggest_project_name,
)

bl_info = {
    "name": "Spline Maker I/O",
    "author": "OpenAI Codex",
    "version": (1, 0, 0),
    "blender": (5, 1, 0),
    "location": "File > Import/Export",
    "description": "Import and export SplineMaker JSON projects as Blender NURBS curves",
    "category": "Import-Export",
}


def _report_messages(operator: Operator, level: set[str], messages: list[str]) -> None:
    for message in messages:
        operator.report(level, message)


class IMPORT_SCENE_OT_spline_maker_json(Operator, ImportHelper):
    bl_idname = "import_scene.spline_maker_json"
    bl_label = "Import SplineMaker JSON"
    bl_options = {"PRESET", "UNDO"}

    filename_ext = ".json"
    filter_glob: StringProperty(default="*.json", options={"HIDDEN"})
    files: CollectionProperty(
        name="Files",
        type=bpy.types.OperatorFileListElement,
        options={"HIDDEN", "SKIP_SAVE"},
    )
    directory: StringProperty(subtype="DIR_PATH", options={"HIDDEN"})
    select_result: BoolProperty(
        name="Select Result",
        description="Select and activate the imported curve object or objects after import",
        default=True,
    )

    def _iter_filepaths(self) -> list[str]:
        if self.files:
            base_dir = Path(self.directory)
            return [str(base_dir / entry.name) for entry in self.files]
        return [self.filepath]

    def execute(self, context: bpy.types.Context):
        filepaths = self._iter_filepaths()
        imported_objects = []
        all_warnings: list[str] = []

        for filepath in filepaths:
            try:
                project, warnings = load_project(filepath)
                object_name = Path(filepath).stem or DEFAULT_OBJECT_NAME
                curve_object, build_warnings = build_curve_object_from_project(
                    context,
                    project,
                    object_name=object_name,
                    target_object=None,
                )
                imported_objects.append(curve_object)
                all_warnings.extend([f"{Path(filepath).name}: {msg}" for msg in warnings + build_warnings])
            except ValueError as exc:
                all_warnings.append(f"{Path(filepath).name}: {exc}")
            except Exception as exc:  # pragma: no cover - Blender runtime safety
                self.report({"ERROR"}, f"SplineMaker import failed: {exc}")
                return {"CANCELLED"}

        if not imported_objects:
            _report_messages(self, {"WARNING"}, all_warnings)
            self.report({"ERROR"}, "No SplineMaker files were imported")
            return {"CANCELLED"}

        if self.select_result:
            for obj in context.selected_objects:
                obj.select_set(False)
            for obj in imported_objects:
                obj.select_set(True)
            context.view_layer.objects.active = imported_objects[-1]

        _report_messages(self, {"WARNING"}, all_warnings)
        self.report(
            {"INFO"},
            "Imported %d file(s) as %d new curve object(s)"
            % (len(imported_objects), len(imported_objects)),
        )
        return {"FINISHED"}


class EXPORT_SCENE_OT_spline_maker_json(Operator, ExportHelper):
    bl_idname = "export_scene.spline_maker_json"
    bl_label = "Export SplineMaker JSON"

    filename_ext = ".json"
    filter_glob: StringProperty(default="*.json", options={"HIDDEN"})

    source_mode: EnumProperty(
        name="Source Curves",
        description="Choose which curve objects should be exported",
        items=[
            ("AUTO", "Auto", "Use the active curve, then selected curves, then tagged SplineMaker curves"),
            ("ACTIVE", "Active", "Export only the active curve object"),
            ("SELECTED", "Selected", "Export all selected curve objects"),
            ("TAGGED", "Tagged", "Export curve objects previously imported from SplineMaker"),
            ("ALL", "All Curves", "Export every curve object in the scene"),
        ],
        default="AUTO",
    )

    def invoke(self, context: bpy.types.Context, event):
        curve_objects = resolve_export_objects(context, self.source_mode)
        if not self.filepath:
            suggested_name = suggest_project_name(context, curve_objects)
            self.filepath = str(Path(bpy.path.abspath("//")) / f"{suggested_name}.json")

        return ExportHelper.invoke(self, context, event)

    def draw(self, context: bpy.types.Context) -> None:
        layout = self.layout
        layout.prop(self, "source_mode")

    def execute(self, context: bpy.types.Context):
        try:
            curve_objects = resolve_export_objects(context, self.source_mode)
            if not curve_objects:
                raise ValueError("No curve objects were found for export")

            warnings: list[str] = []
            export_count = 0

            if len(curve_objects) == 1:
                output_paths = [(curve_objects[0], Path(self.filepath))]
            else:
                base_path = Path(self.filepath)
                export_dir = base_path if base_path.suffix.lower() != ".json" else base_path.parent
                warnings.append(
                    "Multiple objects selected; exporting one JSON file per object into '%s'"
                    % str(export_dir)
                )
                output_paths = []
                for curve_object in curve_objects:
                    project_name = suggest_project_name(context, [curve_object])
                    safe_name = bpy.path.clean_name(project_name) or bpy.path.clean_name(curve_object.name)
                    output_paths.append((curve_object, export_dir / f"{safe_name}.json"))

            for curve_object, output_path in output_paths:
                project_name = Path(output_path).stem or suggest_project_name(context, [curve_object])
                project, object_warnings = project_from_curve_objects(
                    [curve_object],
                    project_name=project_name,
                    source_path=str(output_path),
                    version=DEFAULT_PROJECT_VERSION,
                    curve_smoothness=DEFAULT_CURVE_SMOOTHNESS,
                    action_area_left=DEFAULT_ACTION_AREA_SIZE,
                    action_area_right=DEFAULT_ACTION_AREA_SIZE,
                )

                if not project.splines:
                    warnings.append(f"{curve_object.name}: no valid NURBS splines were available for export")
                    continue

                save_project(str(output_path), project)
                store_project_metadata(curve_object, project)
                export_count += 1
                warnings.extend([f"{curve_object.name}: {msg}" for msg in object_warnings])

            if export_count == 0:
                raise ValueError("No valid NURBS splines were available for export")
        except ValueError as exc:
            self.report({"ERROR"}, str(exc))
            return {"CANCELLED"}
        except Exception as exc:  # pragma: no cover - Blender runtime safety
            self.report({"ERROR"}, f"SplineMaker export failed: {exc}")
            return {"CANCELLED"}

        _report_messages(self, {"WARNING"}, warnings)
        self.report(
            {"INFO"},
            f"Exported {export_count} SplineMaker project file(s)",
        )
        return {"FINISHED"}


def menu_func_import(self, _context):
    self.layout.operator(
        IMPORT_SCENE_OT_spline_maker_json.bl_idname,
        text="SplineMaker Project (.json)",
    )


def menu_func_export(self, _context):
    self.layout.operator(
        EXPORT_SCENE_OT_spline_maker_json.bl_idname,
        text="SplineMaker Project (.json)",
    )


classes = (
    IMPORT_SCENE_OT_spline_maker_json,
    EXPORT_SCENE_OT_spline_maker_json,
)


def register():
    for cls in classes:
        bpy.utils.register_class(cls)
    bpy.types.TOPBAR_MT_file_import.append(menu_func_import)
    bpy.types.TOPBAR_MT_file_export.append(menu_func_export)


def unregister():
    bpy.types.TOPBAR_MT_file_import.remove(menu_func_import)
    bpy.types.TOPBAR_MT_file_export.remove(menu_func_export)
    for cls in reversed(classes):
        bpy.utils.unregister_class(cls)


if __name__ == "__main__":
    register()
