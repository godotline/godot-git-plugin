@tool
class_name SceneInspectorColorAdapter
extends RefCounted

const COLOR_ADDED := Color("#54c88a")
const COLOR_MODIFIED := Color("#f4c95d")
const COLOR_DELETED := Color("#ed6a5a")

var editor_interface
var original_modulate: Dictionary = {}
var original_tooltips: Dictionary = {}
var active_path := ""
var active_signature := ""
var active_control_ids: Array[int] = []

func setup(interface_value) -> void:
	editor_interface = interface_value

func clear() -> void:
	for control in original_modulate.keys():
		if is_instance_valid(control):
			control.modulate = original_modulate[control]
			if original_tooltips.has(control):
				control.tooltip_text = str(original_tooltips[control])
	original_modulate.clear()
	original_tooltips.clear()
	active_path = ""
	active_signature = ""
	active_control_ids.clear()

func poll(entries: Array, edited_root: Node) -> void:
	var entry := _selected_entry(entries, edited_root)
	var inspector := _find_inspector()
	if entry.is_empty() or inspector == null:
		clear()
		return
	var controls: Array[Control] = _property_controls(inspector)
	var ids: Array[int] = []
	for control in controls:
		ids.append(control.get_instance_id())
	var path := _entry_path(entry)
	var signature := path + "|" + str(entry.get("property_changes", entry.get("changed_properties", [])))
	if signature == active_signature and ids == active_control_ids:
		return
	clear()
	active_path = path
	active_signature = signature
	active_control_ids = ids
	var changes := _property_change_map(entry)
	for control in controls:
		if not control.has_method("get_edited_property"):
			continue
		var property_name := str(control.call("get_edited_property"))
		if not changes.has(property_name):
			continue
		var change: Dictionary = changes[property_name]
		original_modulate[control] = control.modulate
		original_tooltips[control] = control.tooltip_text
		control.modulate = _property_tint(str(change.get("status", "MODIFIED")))
		control.tooltip_text = "Git Diff %s: %s" % [str(change.get("status", "MODIFIED")), property_name]

func _selected_entry(entries: Array, edited_root: Node) -> Dictionary:
	if editor_interface == null or edited_root == null:
		return {}
	if not editor_interface.has_method("get_selection"):
		return {}
	var selection = editor_interface.call("get_selection")
	if selection == null or not selection.has_method("get_selected_nodes"):
		return {}
	var selected: Array = selection.get_selected_nodes()
	if selected.is_empty() or selected[0] == null:
		return {}
	var selected_node: Node = selected[0]
	var path := str(edited_root.get_path_to(selected_node)).trim_prefix("./")
	for entry in entries:
		if entry is Dictionary and _entry_path(entry) == path:
			return entry
	return {}

func _find_inspector() -> Node:
	if editor_interface == null:
		return null
	if editor_interface.has_method("get_inspector"):
		var inspector = editor_interface.call("get_inspector")
		if inspector is Node:
			return inspector
	if not editor_interface.has_method("get_base_control"):
		return null
	var base_control: Node = editor_interface.call("get_base_control")
	if base_control == null:
		return null
	var docks: Array[Node] = base_control.find_children("Inspector", "InspectorDock", true, false)
	if docks.is_empty():
		return null
	var inspectors: Array[Node] = docks[0].find_children("*", "EditorInspector", true, false)
	return inspectors[0] if not inspectors.is_empty() else null

func _property_controls(inspector: Node) -> Array[Control]:
	var controls: Array[Control] = []
	for child in inspector.find_children("*", "", true, false):
		var control := child as Control
		if control != null and child.get_class().begins_with("EditorProperty") and child.has_method("get_edited_property"):
			controls.append(control)
	return controls

func _property_change_map(entry: Dictionary) -> Dictionary:
	var changes: Dictionary = {}
	var raw_changes: Array = Array(entry.get("property_changes", []))
	if raw_changes.is_empty():
		for property_name in Array(entry.get("changed_properties", [])):
			raw_changes.append({"name": str(property_name), "status": "MODIFIED"})
	for change in raw_changes:
		if change is Dictionary:
			changes[str(change.get("name", ""))] = change
	return changes

func _entry_path(entry: Dictionary) -> String:
	return str(entry.get("path", "")).trim_prefix("./")

func _property_tint(status: String) -> Color:
	match status.to_upper():
		"ADDED":
			return Color(0.78, 1.0, 0.86, 1.0)
		"DELETED":
			return Color(1.0, 0.78, 0.76, 1.0)
		_:
			return Color(1.0, 0.94, 0.72, 1.0)
