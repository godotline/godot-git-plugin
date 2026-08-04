@tool
extends EditorPlugin

const BackendAdapter = preload("res://addons/godot-git-plugin/backend/git_backend_adapter.gd")
const CollaborationDock = preload("res://addons/godot-git-plugin/ui/git_collaboration_dock.gd")

var backend: RefCounted
var panel: MarginContainer
var dock
var bottom_split_state: Dictionary = {}

func _enter_tree() -> void:
	backend = BackendAdapter.new()

	dock = CollaborationDock.new()
	dock.name = "GitCollaborationDock"
	dock.backend = backend
	dock.editor_interface = get_editor_interface()
	dock.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dock.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dock.custom_minimum_size = Vector2(0, 220)
	dock.clip_contents = true
	panel = MarginContainer.new()
	panel.name = "GitCollaborationPanel"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(dock)
	add_control_to_bottom_panel(panel, "Git Collaboration")
	call_deferred("_configure_bottom_panel_resize")
	dock.call_deferred("prepare_startup")

func _exit_tree() -> void:
	_restore_bottom_panel_resize()
	if dock != null:
		dock.cleanup()
		if panel != null:
			remove_control_from_bottom_panel(panel)
			panel.queue_free()
		else:
			dock.queue_free()
		dock = null
		panel = null
	backend = null

func _configure_bottom_panel_resize() -> void:
	var base_control := get_editor_interface().get_base_control()
	if base_control == null:
		return
	for bottom in base_control.find_children("*", "EditorBottomPanel", true, false):
		var split := bottom.get_parent() as SplitContainer
		if split == null:
			continue
		if not bottom_split_state.has(split):
			bottom_split_state[split] = {
				"dragging": split.is_dragging_enabled(),
				"visibility": split.get_dragger_visibility(),
				"highlight": split.is_drag_area_highlight_in_editor_enabled(),
				"margin_begin": split.get_drag_area_margin_begin(),
				"margin_end": split.get_drag_area_margin_end()
			}
		split.set_dragging_enabled(true)
		split.set_dragger_visibility(SplitContainer.DRAGGER_VISIBLE)
		split.set_drag_area_highlight_in_editor(true)
		split.set_drag_area_margin_begin(6)
		split.set_drag_area_margin_end(6)

func _restore_bottom_panel_resize() -> void:
	for split in bottom_split_state.keys():
		if not is_instance_valid(split):
			continue
		var state: Dictionary = bottom_split_state[split]
		split.set_dragging_enabled(bool(state.get("dragging", true)))
		split.set_dragger_visibility(int(state.get("visibility", SplitContainer.DRAGGER_VISIBLE)))
		split.set_drag_area_highlight_in_editor(bool(state.get("highlight", false)))
		split.set_drag_area_margin_begin(int(state.get("margin_begin", 0)))
		split.set_drag_area_margin_end(int(state.get("margin_end", 0)))
	bottom_split_state.clear()
