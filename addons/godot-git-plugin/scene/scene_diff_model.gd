@tool
class_name SceneDiffModel
extends RefCounted

const ADDED := "ADDED"
const DELETED := "DELETED"
const MODIFIED := "MODIFIED"
const MOVED := "MOVED"
const TYPE_CHANGED := "TYPE_CHANGED"
const CONFLICT := "CONFLICT"

static func compare_text(base_text: String, target_text: String) -> Dictionary:
	var base: Dictionary = parse_text(base_text, true)
	var target: Dictionary = parse_text(target_text, true)
	if not bool(base.get("supported", false)) or not bool(target.get("supported", false)):
		return {
			"supported": false,
			"entries": [],
			"diagnostic": str(base.get("diagnostic", target.get("diagnostic", "Unsupported scene text")))
		}

	var entries: Array = []
	var paths: Dictionary = {}
	var base_nodes: Dictionary = base.get("nodes", {})
	var target_nodes: Dictionary = target.get("nodes", {})
	for path in base_nodes.keys():
		paths[path] = true
	for path in target_nodes.keys():
		paths[path] = true

	for path in paths.keys():
		var has_base: bool = base_nodes.has(path)
		var has_target: bool = target_nodes.has(path)
		var entry: Dictionary
		if not has_base:
			entry = _entry(path, ADDED, {}, target_nodes[path])
		elif not has_target:
			entry = _entry(path, DELETED, base_nodes[path], {})
		else:
			var before: Dictionary = base_nodes[path]
			var after: Dictionary = target_nodes[path]
			var property_changes: Array = _property_changes(before.get("properties", {}), after.get("properties", {}))
			var type_changed := str(before.type) != str(after.type)
			var parent_changed := str(before.parent) != str(after.parent)
			if type_changed:
				entry = _entry(path, TYPE_CHANGED, before, after)
			elif parent_changed:
				entry = _entry(path, MOVED, before, after)
			elif not property_changes.is_empty():
				entry = _entry(path, MODIFIED, before, after)
			else:
				continue
			entry.changed_properties = _property_names(property_changes)
		entries.append(entry)

	_infer_renames(entries)
	return {"supported": true, "entries": entries, "diagnostic": ""}

static func parse_text(text: String, allow_empty: bool = false) -> Dictionary:
	if allow_empty and text.strip_edges().is_empty():
		return {"supported": true, "nodes": {}, "diagnostic": ""}
	if text.find("[gd_scene") < 0:
		return {"supported": false, "nodes": {}, "diagnostic": "Missing [gd_scene] header"}

	var nodes: Dictionary = {}
	var current: Dictionary = {}
	var lines := text.replace("\r\n", "\n").split("\n")
	for line in lines:
		if line.begins_with("[node "):
			_commit_node(nodes, current)
			current = {
				"name": _header_attribute(line, "name"),
				"type": _header_attribute(line, "type"),
				"parent": _header_attribute(line, "parent"),
				"properties": {}
			}
		elif not current.is_empty() and not line.begins_with("["):
			var separator := line.find("=")
			if separator > 0:
				var property_name := line.substr(0, separator).strip_edges()
				if property_name not in ["name", "type", "parent"]:
					current.properties[property_name] = line.substr(separator + 1).strip_edges()
	_commit_node(nodes, current)
	return {"supported": true, "nodes": nodes, "diagnostic": ""}

static func _commit_node(nodes: Dictionary, node: Dictionary) -> void:
	if node.is_empty() or str(node.get("name", "")).is_empty():
		return
	var parent := str(node.get("parent", "."))
	var name := str(node.get("name", ""))
	var path := name if parent.is_empty() or parent == "." else parent + "/" + name
	node["path"] = path
	nodes[path] = node.duplicate(true)

static func _header_attribute(line: String, attribute: String) -> String:
	var expression := RegEx.new()
	expression.compile("(?:^| )" + attribute + "=\\\"([^\\\"]*)\\\"")
	var match := expression.search(line)
	return "" if match == null else match.get_string(1)

static func _property_changes(before: Dictionary, after: Dictionary) -> Array:
	var changes: Array = []
	var names: Dictionary = {}
	for name in before.keys():
		names[name] = true
	for name in after.keys():
		names[name] = true
	for name in names.keys():
		var has_before := before.has(name)
		var has_after := after.has(name)
		if has_before and has_after and str(before.get(name, "")) == str(after.get(name, "")):
			continue
		var status := MODIFIED
		if not has_before:
			status = ADDED
		elif not has_after:
			status = DELETED
		changes.append({
			"name": str(name),
			"status": status,
			"before": str(before.get(name, "")),
			"after": str(after.get(name, ""))
		})
	changes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a.get("name", "")) < str(b.get("name", "")))
	return changes

static func _property_names(changes: Array) -> Array[String]:
	var names: Array[String] = []
	for change in changes:
		if change is Dictionary:
			names.append(str(change.get("name", "")))
	return names

static func _entry(path: String, status: String, before: Dictionary, after: Dictionary) -> Dictionary:
	var property_changes: Array = _property_changes(before.get("properties", {}), after.get("properties", {}))
	return {
		"path": path,
		"status": status,
		"type": str(after.get("type", before.get("type", ""))),
		"parent": str(after.get("parent", before.get("parent", ""))),
		"changed_properties": _property_names(property_changes),
		"property_changes": property_changes,
		"before": before.duplicate(true),
		"after": after.duplicate(true)
	}

static func _infer_renames(entries: Array) -> void:
	var deleted: Array = []
	var added: Array = []
	for entry in entries:
		if entry.status == DELETED:
			deleted.append(entry)
		elif entry.status == ADDED:
			added.append(entry)
	for old_entry in deleted:
		var candidates: Array = []
		for new_entry in added:
			if str(old_entry.before.get("type", "")) == str(new_entry.after.get("type", "")) and _fingerprint(old_entry.before) == _fingerprint(new_entry.after):
				candidates.append(new_entry)
		if candidates.size() == 1:
			var new_entry: Dictionary = candidates[0]
			old_entry.status = MOVED
			old_entry["moved_to"] = new_entry.path
			new_entry.status = MOVED
			new_entry["moved_from"] = old_entry.path

static func _fingerprint(node: Dictionary) -> String:
	var properties: Dictionary = node.get("properties", {})
	var keys := properties.keys()
	keys.sort()
	var values: Array[String] = []
	for key in keys:
		values.append(str(key) + "=" + str(properties[key]))
	return str(node.get("type", "")) + "|" + "|".join(values)
