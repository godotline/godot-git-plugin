@tool
extends EditorPlugin

const BackendAdapter = preload("res://addons/godot-git-plugin/backend/git_backend_adapter.gd")
const CollaborationDock = preload("res://addons/godot-git-plugin/ui/git_collaboration_dock.gd")

var backend: RefCounted
var dock

func _enter_tree() -> void:
	backend = BackendAdapter.new()
	backend.initialize(ProjectSettings.globalize_path("res://"))

	dock = CollaborationDock.new()
	dock.name = "GitCollaborationDock"
	dock.backend = backend
	dock.editor_interface = get_editor_interface()
	add_control_to_bottom_panel(dock, "Git Collaboration")
	dock.refresh()

func _exit_tree() -> void:
	if dock != null:
		dock.cleanup()
		remove_control_from_bottom_panel(dock)
		dock.queue_free()
		dock = null
	backend = null
