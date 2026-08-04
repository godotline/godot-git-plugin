@tool
class_name SceneTreeColorAdapter
extends RefCounted

const COLOR_ADDED := Color("#54c88a")
const COLOR_MODIFIED := Color("#f4c95d")
const COLOR_DELETED := Color("#ed6a5a")

var editor_interface
var original_colors: Dictionary = {}

func setup(interface_value) -> void:
	editor_interface = interface_value

func clear() -> void:
	for item in original_colors.keys():
		if is_instance_valid(item):
			var state: Dictionary = original_colors[item]
			if bool(state.get("custom", false)):
				item.set_custom_color(0, state.get("color", Color.WHITE))
			elif item.has_method("clear_custom_color"):
				item.clear_custom_color(0)
	original_colors.clear()

func apply(entries: Array, fallback_tree: Tree) -> bool:
	clear()
	if fallback_tree != null:
		fallback_tree.visible = false
	var tree := _find_scene_tree()
	if tree == null:
		_build_fallback(entries, fallback_tree)
		return false
	var by_path: Dictionary = {}
	for entry in entries:
		by_path[str(entry.get("path", ""))] = entry
	_color_tree_items(tree.get_root(), "", by_path)
	return true

func _find_scene_tree() -> Tree:
	if editor_interface == null or not editor_interface.has_method("get_scene_tree_dock"):
		return null
	var dock = editor_interface.call("get_scene_tree_dock")
	if dock == null:
		return null
	var trees := dock.find_children("*", "Tree", true, false)
	return trees[0] if not trees.is_empty() else null

func _color_tree_items(item: TreeItem, parent_path: String, by_path: Dictionary) -> void:
	if item == null:
		return
	var item_name := item.get_text(0)
	var path := _join_path(parent_path, item_name)
	if by_path.has(path):
		original_colors[item] = {
			"color": item.get_custom_color(0),
			"custom": item.has_method("is_custom_set_as_color") and item.is_custom_set_as_color(0)
		}
		item.set_custom_color(0, _status_color(str(by_path[path].get("status", "MODIFIED"))))
		item.set_tooltip_text(0, str(by_path[path].get("status", "MODIFIED")) + " " + path)
	var child := item.get_first_child()
	while child != null:
		_color_tree_items(child, path, by_path)
		child = child.get_next()

func _build_fallback(entries: Array, tree: Tree) -> void:
	if tree == null:
		return
	tree.visible = true
	tree.clear()
	var root := tree.create_item()
	for entry in entries:
		var item := tree.create_item(root)
		item.set_text(0, str(entry.get("path", "")))
		item.set_text(1, str(entry.get("status", "MODIFIED")))
		item.set_custom_color(1, _status_color(str(entry.get("status", "MODIFIED"))))

func _status_color(status: String) -> Color:
	match status.to_upper():
		"ADDED":
			return COLOR_ADDED
		"DELETED", "CONFLICT":
			return COLOR_DELETED
		_:
			return COLOR_MODIFIED

func _join_path(parent_path: String, item_name: String) -> String:
	if item_name.is_empty():
		return parent_path
	return item_name if parent_path.is_empty() else parent_path + "/" + item_name
