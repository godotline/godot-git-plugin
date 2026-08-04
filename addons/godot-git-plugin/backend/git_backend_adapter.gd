@tool
class_name GitBackendAdapter
extends RefCounted

var native: Object
var project_path: String

func initialize(path: String) -> Dictionary:
	project_path = path
	if not ClassDB.class_exists("GitPlugin"):
		return _error("backend_unavailable", "GitPlugin GDExtension is not loaded")

	# GitPlugin is registered as an editor-only GDExtension class. Godot 4.7
	# does not expose EditorVCSInterface.get_singleton(), so instantiate it
	# through the class registry instead of relying on the older VCS API.
	native = ClassDB.instantiate("GitPlugin")
	if native == null:
		return _error("backend_unavailable", "Could not instantiate GitPlugin")
	return _call("collaboration_initialize", [project_path])

func repository_state() -> Dictionary:
	return _call("collaboration_get_repository_state")

func refs() -> Array:
	if native == null or not native.has_method("collaboration_get_refs"):
		return []
	var value = native.call("collaboration_get_refs")
	return Array(value)

func diff_refs(base_ref: String, target_ref: String, path_filter: String = "") -> Dictionary:
	return _call("collaboration_diff_refs", [base_ref, target_ref, path_filter])

func blob(ref_name: String, path: String) -> Dictionary:
	return _call("collaboration_get_blob", [ref_name, path])

func analyze_merge(target_ref: String) -> Dictionary:
	return _call("collaboration_analyze_merge", [target_ref])

func merge_ref(target_ref: String) -> Dictionary:
	return _call("collaboration_merge_ref", [target_ref])

func conflicts() -> Array:
	if native == null or not native.has_method("collaboration_get_conflicts"):
		return []
	return Array(native.call("collaboration_get_conflicts"))

func conflict_blob(path: String, stage: int) -> Dictionary:
	return _call("collaboration_get_conflict_blob", [path, stage])

func write_and_stage(path: String, content: String) -> Dictionary:
	return _call("collaboration_write_and_stage", [path, content])

func modified_files() -> Array:
	if native == null or not native.has_method("collaboration_get_worktree_files"):
		return []
	return Array(native.call("collaboration_get_worktree_files"))

func commit(message: String) -> Dictionary:
	return _call("collaboration_commit", [message])

func fetch(remote: String = "origin") -> Dictionary:
	return _call("collaboration_fetch", [remote])

func _call(method_name: String, args: Array = []) -> Dictionary:
	if native == null:
		return _error("backend_unavailable", "GitPlugin is not initialized")
	if not native.has_method(method_name):
		return _error("method_unavailable", "GitPlugin does not expose " + method_name)
	var value = native.callv(method_name, args)
	if value is Dictionary:
		return value
	return _error("invalid_backend_result", "GitPlugin returned an invalid result")

func _error(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message, "data": {}}
