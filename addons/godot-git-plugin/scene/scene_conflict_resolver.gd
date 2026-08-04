@tool
class_name SceneConflictResolver
extends RefCounted

const SceneDiff = preload("res://addons/godot-git-plugin/scene/scene_diff_model.gd")

static func analyze(base_text: String, ours_text: String, theirs_text: String) -> Dictionary:
	var base := SceneDiff.parse_text(base_text)
	var ours := SceneDiff.parse_text(ours_text)
	var theirs := SceneDiff.parse_text(theirs_text)
	if not bool(base.get("supported", false)) or not bool(ours.get("supported", false)) or not bool(theirs.get("supported", false)):
		return {
			"supported": false,
			"requires_user_choice": true,
			"diagnostic": "One or more conflict stages are not parseable as a scene"
		}

	var decisions: Array = []
	var paths: Dictionary = {}
	for path in base.nodes.keys():
		paths[path] = true
	for path in ours.nodes.keys():
		paths[path] = true
	for path in theirs.nodes.keys():
		paths[path] = true

	for path in paths.keys():
		var base_node: Dictionary = base.nodes.get(path, {})
		var ours_node: Dictionary = ours.nodes.get(path, {})
		var theirs_node: Dictionary = theirs.nodes.get(path, {})
		var property_names: Dictionary = {}
		for node in [base_node, ours_node, theirs_node]:
			for property_name in node.get("properties", {}).keys():
				property_names[property_name] = true
		for property_name in property_names.keys():
			var base_value := str(base_node.get("properties", {}).get(property_name, ""))
			var ours_value := str(ours_node.get("properties", {}).get(property_name, ""))
			var theirs_value := str(theirs_node.get("properties", {}).get(property_name, ""))
			var resolution := _resolution(base_value, ours_value, theirs_value)
			if resolution == "conflict":
				decisions.append({
					"path": path,
					"property": property_name,
					"base": base_value,
					"ours": ours_value,
					"theirs": theirs_value,
					"resolution": resolution
				})
	return {
		"supported": true,
		"requires_user_choice": not decisions.is_empty(),
		"conflicts": decisions
	}

static func choose_side(ours_text: String, theirs_text: String, side: String) -> Dictionary:
	if side == "ours":
		return {"ok": true, "text": ours_text, "side": "ours"}
	if side == "theirs":
		return {"ok": true, "text": theirs_text, "side": "theirs"}
	return {"ok": false, "code": "invalid_side", "message": "Choose ours or theirs"}

static func choose_side_with_base(base_text: String, ours_text: String, theirs_text: String, side: String) -> Dictionary:
	if side == "base":
		return {"ok": true, "text": base_text, "side": "base"}
	return choose_side(ours_text, theirs_text, side)

static func auto_merge_text(base_text: String, ours_text: String, theirs_text: String) -> Dictionary:
	if ours_text == theirs_text:
		return {"ok": true, "text": ours_text, "side": "same"}
	if ours_text == base_text:
		return {"ok": true, "text": theirs_text, "side": "theirs"}
	if theirs_text == base_text:
		return {"ok": true, "text": ours_text, "side": "ours"}
	return {
		"ok": false,
		"code": "manual_choice_required",
		"message": "Both sides changed the file; choose a side or edit the result"
	}

static func _resolution(base_value: String, ours_value: String, theirs_value: String) -> String:
	if ours_value == theirs_value:
		return "same"
	if ours_value == base_value:
		return "theirs"
	if theirs_value == base_value:
		return "ours"
	return "conflict"
