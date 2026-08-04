@tool
class_name SceneTreeColorAdapter
extends RefCounted

const COLOR_ADDED := Color("#54c88a")
const COLOR_MODIFIED := Color("#f4c95d")
const COLOR_DELETED := Color("#ed6a5a")
const NORMAL_ALPHA := 0.82
const HOVER_ALPHA := 0.90
const NORMAL_BACKGROUND_ALPHA := 0.14
const HOVER_BACKGROUND_ALPHA := 0.30

var editor_interface
var original_colors: Dictionary = {}
var item_status: Dictionary = {}
var scene_tree_root_name := ""
var active_tree: Tree
var active_root: TreeItem
var hovered_item: TreeItem

func setup(interface_value) -> void:
	editor_interface = interface_value

func clear() -> void:
	for item in original_colors.keys():
		if is_instance_valid(item):
			_restore_item(item)
	original_colors.clear()
	item_status.clear()
	hovered_item = null
	active_tree = null
	active_root = null
	scene_tree_root_name = ""

func apply(entries: Array, fallback_tree: Tree) -> bool:
	clear()
	if fallback_tree != null:
		fallback_tree.visible = false
	var tree := _find_scene_tree()
	if tree == null:
		_build_fallback(entries, fallback_tree)
		return false
	var root := tree.get_root()
	if root == null:
		_build_fallback(entries, fallback_tree)
		return false
	active_tree = tree
	active_root = root
	scene_tree_root_name = root.get_text(0)
	_sync_tree_items(entries)
	_update_hover()
	return true

# The native SceneTreeEditor rebuilds TreeItems after scene changes and selection
# changes. Polling only while coloring is enabled keeps the feature explicit and
# lets the adapter restore status colors after those rebuilds.
func poll(entries: Array, fallback_tree: Tree) -> void:
	var tree := _find_scene_tree()
	if tree == null or tree.get_root() == null:
		if active_tree != null or (fallback_tree != null and not fallback_tree.visible):
			apply(entries, fallback_tree)
		return
	if active_tree != tree or active_root != tree.get_root():
		apply(entries, fallback_tree)
		return
	_sync_tree_items(entries)
	_update_hover()

func _find_scene_tree() -> Tree:
	if editor_interface == null:
		return null
	var dock: Node = null
	if editor_interface.has_method("get_scene_tree_dock"):
		dock = editor_interface.call("get_scene_tree_dock")
	if dock == null and editor_interface.has_method("get_base_control"):
		var base_control: Node = editor_interface.call("get_base_control")
		if base_control != null:
			var scene_docks: Array[Node] = base_control.find_children("*", "SceneTreeDock", true, false)
			if not scene_docks.is_empty():
				dock = scene_docks[0]
			else:
				var scene_editors: Array[Node] = base_control.find_children("*", "SceneTreeEditor", true, false)
				for scene_editor in scene_editors:
					var editor_trees: Array[Node] = scene_editor.find_children("*", "Tree", true, false)
					for candidate in editor_trees:
						if candidate is Tree and candidate.get_root() != null:
							return candidate
	if dock == null:
		return null
	var trees: Array[Node] = dock.find_children("*", "Tree", true, false)
	for candidate in trees:
		if candidate is Tree and candidate.get_root() != null:
			return candidate
	return null

func _sync_tree_items(entries: Array) -> void:
	if active_tree == null or active_root == null:
		return
	var by_path: Dictionary = {}
	for entry in entries:
		if entry is Dictionary:
			by_path[str(entry.get("path", ""))] = entry
	_color_tree_items(active_root, "", by_path)
	# A TreeItem can be removed by SceneTreeEditor between polls.
	for item in item_status.keys():
		if not is_instance_valid(item):
			item_status.erase(item)

func _color_tree_items(item: TreeItem, parent_path: String, by_path: Dictionary) -> void:
	if item == null:
		return
	var item_name := item.get_text(0)
	var path := _join_path(parent_path, item_name)
	var entry: Dictionary = _entry_for_path(path, by_path)
	if not entry.is_empty():
		if not original_colors.has(item):
			_remember_item(item)
		var status := str(entry.get("status", "MODIFIED"))
		item_status[item] = status
		_apply_item_style(item, status, item == hovered_item)
		item.set_tooltip_text(0, status + " " + str(entry.get("path", path)))
	elif item_status.has(item):
		_restore_item(item)
		item_status.erase(item)
	var child := item.get_first_child()
	while child != null:
		_color_tree_items(child, path, by_path)
		child = child.get_next()

func _entry_for_path(path: String, by_path: Dictionary) -> Dictionary:
	if by_path.has(path):
		return by_path[path]
	var root_prefix := scene_tree_root_name + "/"
	if not scene_tree_root_name.is_empty() and path.begins_with(root_prefix):
		var rootless_path := path.substr(root_prefix.length())
		if by_path.has(rootless_path):
			return by_path[rootless_path]
	return {}

func _remember_item(item: TreeItem) -> void:
	var color := item.get_custom_color(0)
	var background := item.get_custom_bg_color(0) if item.has_method("get_custom_bg_color") else Color.BLACK
	original_colors[item] = {
		"color": color,
		"color_set": _has_custom_color(item, 0, color),
		"background": background,
		"background_set": _has_custom_color(item, 0, background),
		"tooltip": item.get_tooltip_text(0)
	}

func _restore_item(item: TreeItem) -> void:
	var state: Dictionary = original_colors.get(item, {})
	if bool(state.get("color_set", false)):
		item.set_custom_color(0, state.get("color", Color.WHITE))
	elif item.has_method("clear_custom_color"):
		item.clear_custom_color(0)
	if item.has_method("set_custom_bg_color"):
		if bool(state.get("background_set", false)):
			item.set_custom_bg_color(0, state.get("background", Color.BLACK))
		elif item.has_method("clear_custom_bg_color"):
			item.clear_custom_bg_color(0)
	if state.has("tooltip"):
		item.set_tooltip_text(0, str(state.get("tooltip", "")))

func _has_custom_color(item: TreeItem, column: int, color: Color) -> bool:
	if item.has_method("is_custom_set_as_color"):
		return item.is_custom_set_as_color(column)
	return color != Color(0.0, 0.0, 0.0, 1.0)

func _apply_item_style(item: TreeItem, status: String, hovered: bool) -> void:
	var color := _status_color(status)
	var foreground_alpha := HOVER_ALPHA if hovered else NORMAL_ALPHA
	item.set_custom_color(0, _with_alpha(color, foreground_alpha))
	if item.has_method("set_custom_bg_color"):
		var background_alpha := HOVER_BACKGROUND_ALPHA if hovered else NORMAL_BACKGROUND_ALPHA
		item.set_custom_bg_color(0, _with_alpha(color, background_alpha), false)

func _update_hover() -> void:
	if active_tree == null:
		return
	var next_item: TreeItem = null
	var local_position := active_tree.get_local_mouse_position()
	if Rect2(Vector2.ZERO, active_tree.size).has_point(local_position):
		var candidate := active_tree.get_item_at_position(local_position)
		if candidate != null and item_status.has(candidate):
			next_item = candidate
	if next_item == hovered_item:
		return
	var previous := hovered_item
	hovered_item = next_item
	if previous != null and is_instance_valid(previous) and item_status.has(previous):
		_apply_item_style(previous, str(item_status[previous]), false)
	if hovered_item != null:
		_apply_item_style(hovered_item, str(item_status[hovered_item]), true)

func _build_fallback(entries: Array, tree: Tree) -> void:
	if tree == null:
		return
	tree.visible = true
	tree.clear()
	var root := tree.create_item()
	for entry in entries:
		if not entry is Dictionary:
			continue
		var item := tree.create_item(root)
		var status := str(entry.get("status", "MODIFIED"))
		item.set_text(0, str(entry.get("path", "")))
		item.set_text(1, status)
		item.set_custom_color(0, _with_alpha(_status_color(status), NORMAL_ALPHA))
		item.set_custom_color(1, _status_color(status))

func _status_color(status: String) -> Color:
	match status.to_upper():
		"ADDED":
			return COLOR_ADDED
		"DELETED", "CONFLICT":
			return COLOR_DELETED
		_:
			return COLOR_MODIFIED

func _with_alpha(color: Color, alpha: float) -> Color:
	return Color(color.r, color.g, color.b, alpha)

func _join_path(parent_path: String, item_name: String) -> String:
	if item_name.is_empty():
		return parent_path
	return item_name if parent_path.is_empty() else parent_path + "/" + item_name
