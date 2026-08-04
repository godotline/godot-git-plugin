@tool
class_name SceneOverlayRenderer
extends RefCounted

const COLOR_ADDED := Color(0.33, 0.78, 0.55, 0.28)
const COLOR_MODIFIED := Color(0.96, 0.79, 0.30, 0.28)
const COLOR_DELETED := Color(0.93, 0.42, 0.35, 0.45)

var enabled := false
var before_opacity := 0.5
var after_opacity := 0.5
var overlay_root: Node
var attached_scene_root: Node

func set_enabled(value: bool) -> void:
	enabled = value
	if not enabled:
		clear()

func attach_to(scene_root: Node) -> void:
	if scene_root == null:
		return
	if not is_instance_valid(overlay_root) or attached_scene_root != scene_root or not _same_overlay_kind(scene_root):
		clear()
		if is_instance_valid(overlay_root):
			if overlay_root.get_parent() != null:
				overlay_root.get_parent().remove_child(overlay_root)
			overlay_root.free()
		overlay_root = _new_overlay_root(scene_root)
		overlay_root.name = "__GitDiffOverlay"
		overlay_root.owner = null
		overlay_root.process_mode = Node.PROCESS_MODE_DISABLED
		overlay_root.set_meta("_edit_lock_", true)
		overlay_root.set_meta("_git_diff_overlay", true)
		attached_scene_root = scene_root
	if overlay_root.get_parent() != scene_root:
		if overlay_root.get_parent() != null:
			overlay_root.get_parent().remove_child(overlay_root)
		scene_root.add_child(overlay_root)
		overlay_root.owner = null

func clear() -> void:
	if not is_instance_valid(overlay_root):
		return
	for child in overlay_root.get_children():
		overlay_root.remove_child(child)
		child.free()

func detach() -> void:
	clear()
	if is_instance_valid(overlay_root):
		if overlay_root.get_parent() != null:
			overlay_root.get_parent().remove_child(overlay_root)
		overlay_root.free()
	overlay_root = null
	attached_scene_root = null

func apply_diff(scene_root: Node, entries: Array, before_root: Node = null, after_root: Node = null, merge_review := false) -> void:
	if not enabled:
		clear()
		return
	if scene_root == null:
		clear()
		return
	attach_to(scene_root)
	clear()
	for entry in entries:
		if not entry is Dictionary:
			continue
		var path := NodePath(str(entry.get("path", "")))
		var status := str(entry.get("status", "MODIFIED"))
		var before_node := _resolve_node(before_root, path)
		var after_node := _resolve_node(after_root, path)
		var color := _status_color(status)
		if merge_review:
			if before_node != null:
				_add_duplicate(before_node, _with_alpha(COLOR_DELETED, before_opacity))
			if after_node != null:
				_add_duplicate(after_node, _with_alpha(COLOR_ADDED, after_opacity))
			continue
		if status == "DELETED" and before_node != null:
			_add_duplicate(before_node, COLOR_DELETED)
		elif after_node != null:
			_add_duplicate(after_node, color)
		else:
			var current_node := _resolve_node(scene_root, path)
			if current_node != null:
				_add_duplicate(current_node, color)

func overlay_count() -> int:
	return 0 if not is_instance_valid(overlay_root) else overlay_root.get_child_count()

func _add_duplicate(source: Node, color: Color) -> void:
	var duplicate := source.duplicate(Node.DUPLICATE_USE_INSTANTIATION)
	if duplicate == null:
		return
	_strip_behavior(duplicate)
	duplicate.set_meta("_edit_lock_", true)
	duplicate.set_meta("_git_diff_overlay", true)
	overlay_root.add_child(duplicate)
	duplicate.owner = null
	if duplicate is Node3D and source is Node3D:
		if source.is_inside_tree():
			duplicate.global_transform = source.global_transform
		else:
			duplicate.transform = _relative_transform_3d(source)
	elif duplicate is Node2D and source is Node2D:
		if source.is_inside_tree():
			duplicate.global_transform = source.global_transform
		else:
			duplicate.transform = _relative_transform_2d(source)
	if source is CollisionShape3D and duplicate is CollisionShape3D:
		_add_collision_visual(duplicate, source)
	_apply_color(duplicate, color)
	if duplicate is CanvasItem:
		duplicate.show_behind_parent = false

func _relative_transform_3d(source: Node3D) -> Transform3D:
	var chain: Array[Node3D] = []
	var current: Node = source
	while current is Node3D:
		chain.push_front(current as Node3D)
		current = current.get_parent()
	var result := Transform3D.IDENTITY
	for node in chain:
		result = result * node.transform
	return result

func _relative_transform_2d(source: Node2D) -> Transform2D:
	var chain: Array[Node2D] = []
	var current: Node = source
	while current is Node2D:
		chain.push_front(current as Node2D)
		current = current.get_parent()
	var result := Transform2D.IDENTITY
	for node in chain:
		result = result * node.transform
	return result

func _strip_behavior(node: Node) -> void:
	node.process_mode = Node.PROCESS_MODE_DISABLED
	node.set_meta("_edit_lock_", true)
	node.set_meta("_git_diff_overlay", true)
	if node.get_script() != null:
		node.set_script(null)
	if node.has_method("set_process"):
		node.set_process(false)
	if node.has_method("set_physics_process"):
		node.set_physics_process(false)
	if node is CollisionObject3D:
		node.collision_layer = 0
		node.collision_mask = 0
	for child in node.get_children():
		_strip_behavior(child)

func _add_collision_visual(duplicate: CollisionShape3D, source: CollisionShape3D) -> void:
	var shape := source.shape
	if shape == null:
		return
	var mesh: Mesh = null
	if shape.has_method("get_debug_mesh"):
		var debug_mesh = shape.call("get_debug_mesh")
		if debug_mesh is Mesh:
			mesh = debug_mesh
	if mesh == null:
		return
	var visual := MeshInstance3D.new()
	visual.name = "__GitDiffCollisionShape"
	visual.mesh = mesh
	visual.owner = null
	visual.process_mode = Node.PROCESS_MODE_DISABLED
	visual.set_meta("_edit_lock_", true)
	visual.set_meta("_git_diff_overlay", true)
	duplicate.add_child(visual)

func _apply_color(node: Node, color: Color) -> void:
	if node is GeometryInstance3D:
		var material := StandardMaterial3D.new()
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.albedo_color = _with_alpha(color, maxf(color.a, 0.42))
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.no_depth_test = true
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.render_priority = 1
		node.material_overlay = material
	elif node is CanvasItem:
		node.modulate = color
	for child in node.get_children():
		_apply_color(child, color)

func _new_overlay_root(scene_root: Node) -> Node:
	if scene_root is Node3D:
		return Node3D.new()
	if scene_root is Node2D:
		return Node2D.new()
	return Node.new()

func _same_overlay_kind(scene_root: Node) -> bool:
	if not is_instance_valid(overlay_root):
		return false
	if scene_root is Node3D:
		return overlay_root is Node3D
	if scene_root is Node2D:
		return overlay_root is Node2D
	return not (overlay_root is Node2D) and not (overlay_root is Node3D)

func _resolve_node(root: Node, path: NodePath) -> Node:
	if root == null:
		return null
	var value := str(path)
	if value.is_empty() or value == "." or value == str(root.name):
		return root
	if value.begins_with(str(root.name) + "/"):
		value = value.substr(str(root.name).length() + 1)
	if root.has_node(NodePath(value)):
		return root.get_node(NodePath(value))
	return null

func _status_color(status: String) -> Color:
	match status:
		"ADDED":
			return COLOR_ADDED
		"DELETED":
			return COLOR_DELETED
		_:
			return COLOR_MODIFIED

func _with_alpha(color: Color, alpha: float) -> Color:
	return Color(color.r, color.g, color.b, alpha)
