@tool
class_name GitCollaborationDock
extends VBoxContainer

const SceneDiff = preload("res://addons/godot-git-plugin/scene/scene_diff_model.gd")
const SceneResolver = preload("res://addons/godot-git-plugin/scene/scene_conflict_resolver.gd")
const SnapshotCache = preload("res://addons/godot-git-plugin/scene/scene_snapshot_cache.gd")
const OverlayRenderer = preload("res://addons/godot-git-plugin/scene/scene_overlay_renderer.gd")
const TreeColorAdapter = preload("res://addons/godot-git-plugin/scene/scene_tree_color_adapter.gd")

const COLOR_ADDED := Color("#54c88a")
const COLOR_MODIFIED := Color("#f4c95d")
const COLOR_DELETED := Color("#ed6a5a")

const MODE_HEAD_TARGET := 0
const MODE_WORKTREE := 1
const MODE_REF_REF := 2
const MODE_MERGE_REVIEW := 3

var backend: RefCounted
var editor_interface
var current_branch_text := ""
var current_repository_state := "idle"
var status_code := "initializing"
var merge_enabled := false
var busy := false

var current_diff_files: Array = []
var current_scene_entries: Array = []
var current_base_ref := ""
var current_target_ref := ""
var current_scene_path := ""
var selected_file_path := ""
var selected_conflict_path := ""
var merge_review := false
var scene_color_enabled := false

var snapshot_cache: RefCounted
var overlay_renderer: RefCounted
var tree_color_adapter: RefCounted
var before_snapshot_root: Node
var after_snapshot_root: Node

var current_branch_label: Label
var status_label: Label
var conflict_info_label: Label
var scene_info_label: Label
var target_ref: OptionButton
var compare_mode: OptionButton
var base_ref_edit: LineEdit
var target_ref_edit: LineEdit
var status_summary_label: Label
var file_tree: Tree
var scene_diff_tree: Tree
var conflict_tree: Tree
var scene_color_toggle: CheckButton
var refresh_button: Button
var fetch_button: Button
var diff_button: Button
var review_button: Button
var clear_review_button: Button
var merge_button: Button
var merge_commit_button: Button
var commit_message_edit: LineEdit
var before_opacity_slider: HSlider
var after_opacity_slider: HSlider
var opacity_box: HBoxContainer

var file_detail: TextEdit
var base_conflict_view: TextEdit
var ours_conflict_view: TextEdit
var theirs_conflict_view: TextEdit
var result_conflict_view: TextEdit
var take_base_button: Button
var take_ours_button: Button
var take_theirs_button: Button
var stage_conflict_button: Button

func _init() -> void:
	snapshot_cache = SnapshotCache.new()
	overlay_renderer = OverlayRenderer.new()
	tree_color_adapter = TreeColorAdapter.new()

func _ready() -> void:
	_build_ui()
	if tree_color_adapter != null:
		tree_color_adapter.setup(editor_interface)

func _build_ui() -> void:
	if current_branch_label != null:
		return

	custom_minimum_size = Vector2(0, 330)
	add_theme_constant_override("separation", 6)

	var header := HBoxContainer.new()
	add_child(header)
	var title := Label.new()
	title.text = "Git Collaboration"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	current_branch_label = Label.new()
	current_branch_label.text = "Current: -"
	header.add_child(current_branch_label)

	var compare_row := HBoxContainer.new()
	add_child(compare_row)
	var mode_label := Label.new()
	mode_label.text = "Compare"
	compare_row.add_child(mode_label)
	compare_mode = OptionButton.new()
	compare_mode.custom_minimum_size = Vector2(145, 0)
	compare_mode.add_item("HEAD -> Target", MODE_HEAD_TARGET)
	compare_mode.add_item("Working tree", MODE_WORKTREE)
	compare_mode.add_item("Ref -> Ref", MODE_REF_REF)
	compare_mode.add_item("Merge review", MODE_MERGE_REVIEW)
	compare_mode.item_selected.connect(_mode_changed)
	compare_row.add_child(compare_mode)
	base_ref_edit = LineEdit.new()
	base_ref_edit.placeholder_text = "Base ref / commit"
	base_ref_edit.custom_minimum_size = Vector2(180, 0)
	base_ref_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	compare_row.add_child(base_ref_edit)
	var arrow := Label.new()
	arrow.text = " -> "
	compare_row.add_child(arrow)
	target_ref_edit = LineEdit.new()
	target_ref_edit.placeholder_text = "Target ref / commit"
	target_ref_edit.custom_minimum_size = Vector2(180, 0)
	target_ref_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	target_ref_edit.text_changed.connect(_target_ref_changed)
	compare_row.add_child(target_ref_edit)
	target_ref = OptionButton.new()
	target_ref.tooltip_text = "Pick a local branch, remote ref, or tag; a commit ID can be typed"
	target_ref.custom_minimum_size = Vector2(180, 0)
	target_ref.item_selected.connect(_ref_picked)
	compare_row.add_child(target_ref)

	var actions := HBoxContainer.new()
	add_child(actions)
	refresh_button = _make_button("Refresh", "Refresh repository state and visible Diff data", refresh)
	actions.add_child(refresh_button)
	fetch_button = _make_button("Fetch", "Fetch explicitly from the configured remote", _fetch)
	actions.add_child(fetch_button)
	diff_button = _make_button("Diff", "Show file, text, and supported scene Diff", _show_diff)
	actions.add_child(diff_button)
	review_button = _make_button("Review", "Show before and after scene layers with independent opacity", _review_merge)
	actions.add_child(review_button)
	clear_review_button = _make_button("Clear review", "Remove temporary review layers", _clear_review)
	actions.add_child(clear_review_button)
	merge_button = _make_button("Merge", "Merge the target ref into the current checkout branch", _merge)
	actions.add_child(merge_button)
	scene_color_toggle = CheckButton.new()
	scene_color_toggle.text = "Color scene"
	scene_color_toggle.tooltip_text = "Enable explicit scene Diff coloring and temporary viewport overlays"
	scene_color_toggle.button_pressed = false
	scene_color_toggle.toggled.connect(_scene_color_changed)
	actions.add_child(scene_color_toggle)

	var summary_row := HBoxContainer.new()
	add_child(summary_row)
	status_label = Label.new()
	status_label.text = "Initializing Git state..."
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	summary_row.add_child(status_label)
	status_summary_label = Label.new()
	status_summary_label.text = ""
	summary_row.add_child(status_summary_label)

	var tabs := TabContainer.new()
	tabs.name = "CollaborationViews"
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(tabs)

	var files_page := VBoxContainer.new()
	files_page.name = "Files"
	tabs.add_child(files_page)
	file_tree = Tree.new()
	file_tree.name = "ChangedFiles"
	file_tree.columns = 3
	file_tree.hide_root = true
	file_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	file_tree.item_selected.connect(_file_selected)
	files_page.add_child(file_tree)
	file_detail = _new_text_view(false)
	file_detail.name = "FileDiff"
	file_detail.custom_minimum_size = Vector2(0, 120)
	files_page.add_child(file_detail)

	var scene_page := VBoxContainer.new()
	scene_page.name = "Scene"
	tabs.add_child(scene_page)
	scene_info_label = Label.new()
	scene_info_label.text = "Scene coloring is off. Enable it manually to scan the edited scene."
	scene_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	scene_page.add_child(scene_info_label)
	scene_diff_tree = Tree.new()
	scene_diff_tree.name = "SceneDiff"
	scene_diff_tree.columns = 3
	scene_diff_tree.hide_root = true
	scene_diff_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scene_page.add_child(scene_diff_tree)
	opacity_box = _build_opacity_controls()
	opacity_box.visible = false
	scene_page.add_child(opacity_box)

	var conflicts_page := VBoxContainer.new()
	conflicts_page.name = "Conflicts"
	tabs.add_child(conflicts_page)
	conflict_tree = Tree.new()
	conflict_tree.name = "ConflictFiles"
	conflict_tree.columns = 3
	conflict_tree.hide_root = true
	conflict_tree.custom_minimum_size = Vector2(0, 90)
	conflict_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	conflict_tree.item_selected.connect(_conflict_selected)
	conflicts_page.add_child(conflict_tree)
	conflict_info_label = Label.new()
	conflict_info_label.text = "Select a conflicted file to inspect Base, Ours, Theirs, and the editable result."
	conflict_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	conflicts_page.add_child(conflict_info_label)
	var conflict_views := TabContainer.new()
	conflict_views.name = "ConflictStages"
	conflict_views.custom_minimum_size = Vector2(0, 150)
	conflict_views.size_flags_vertical = Control.SIZE_EXPAND_FILL
	conflicts_page.add_child(conflict_views)
	base_conflict_view = _new_text_view(false)
	base_conflict_view.name = "Base"
	conflict_views.add_child(base_conflict_view)
	ours_conflict_view = _new_text_view(false)
	ours_conflict_view.name = "Ours"
	conflict_views.add_child(ours_conflict_view)
	theirs_conflict_view = _new_text_view(false)
	theirs_conflict_view.name = "Theirs"
	conflict_views.add_child(theirs_conflict_view)
	result_conflict_view = _new_text_view(true)
	result_conflict_view.name = "Result"
	conflict_views.add_child(result_conflict_view)
	var conflict_actions := HBoxContainer.new()
	conflicts_page.add_child(conflict_actions)
	take_base_button = _make_button("Take Base", "Replace the editable result with conflict stage 1", _take_base)
	conflict_actions.add_child(take_base_button)
	take_ours_button = _make_button("Take Ours", "Replace the editable result with conflict stage 2", _take_ours)
	conflict_actions.add_child(take_ours_button)
	take_theirs_button = _make_button("Take Theirs", "Replace the editable result with conflict stage 3", _take_theirs)
	conflict_actions.add_child(take_theirs_button)
	stage_conflict_button = _make_button("Stage result", "Write the edited result and remove this conflict from the index", _stage_conflict)
	conflict_actions.add_child(stage_conflict_button)

	var commit_row := HBoxContainer.new()
	add_child(commit_row)
	commit_message_edit = LineEdit.new()
	commit_message_edit.placeholder_text = "Merge commit message"
	commit_message_edit.text = "Merge target ref"
	commit_message_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	commit_row.add_child(commit_message_edit)
	merge_commit_button = _make_button("Create merge commit", "Create the pending merge commit explicitly", _create_merge_commit)
	commit_row.add_child(merge_commit_button)

	_mode_changed(MODE_HEAD_TARGET)
	_clear_conflict_views()
	_set_busy(false)

func _make_button(label: String, tooltip: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = label
	button.tooltip_text = tooltip
	button.pressed.connect(callback)
	return button

func _new_text_view(editable: bool) -> TextEdit:
	var view := TextEdit.new()
	view.editable = editable
	view.wrap_mode = TextEdit.LINE_WRAPPING_NONE
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return view

func _build_opacity_controls() -> HBoxContainer:
	var row := HBoxContainer.new()
	var before_label := Label.new()
	before_label.text = "Before"
	row.add_child(before_label)
	before_opacity_slider = HSlider.new()
	before_opacity_slider.min_value = 0.05
	before_opacity_slider.max_value = 1.0
	before_opacity_slider.step = 0.05
	before_opacity_slider.value = 0.5
	before_opacity_slider.custom_minimum_size = Vector2(120, 0)
	before_opacity_slider.value_changed.connect(_before_opacity_changed)
	row.add_child(before_opacity_slider)
	var after_label := Label.new()
	after_label.text = "After"
	row.add_child(after_label)
	after_opacity_slider = HSlider.new()
	after_opacity_slider.min_value = 0.05
	after_opacity_slider.max_value = 1.0
	after_opacity_slider.step = 0.05
	after_opacity_slider.value = 0.5
	after_opacity_slider.custom_minimum_size = Vector2(120, 0)
	after_opacity_slider.value_changed.connect(_after_opacity_changed)
	row.add_child(after_opacity_slider)
	return row

func refresh() -> void:
	_build_ui()
	if tree_color_adapter != null:
		tree_color_adapter.setup(editor_interface)
	if backend == null:
		_set_status("backend_unavailable", "Git backend is not initialized")
		return
	var result: Dictionary = backend.repository_state()
	if not bool(result.get("ok", false)):
		_set_status(str(result.get("code", "state_failed")), str(result.get("message", "Could not read Git state")))
		_clear_refs()
		return
	var data: Dictionary = result.get("data", {})
	current_branch_text = str(data.get("current_branch", ""))
	current_repository_state = str(data.get("repository_state", "idle"))
	current_branch_label.text = "Current: " + (current_branch_text if not current_branch_text.is_empty() else "detached")
	_populate_refs()
	var dirty := bool(data.get("dirty", true))
	var mode := _current_mode()
	merge_enabled = not dirty and not bool(data.get("detached", true)) and current_repository_state == "idle" and not _selected_target().is_empty() and (mode == MODE_HEAD_TARGET or mode == MODE_MERGE_REVIEW)
	merge_button.disabled = not merge_enabled
	merge_commit_button.disabled = busy or current_repository_state != "merge"
	status_summary_label.text = "staged %d  unstaged %d  conflicts %d" % [int(data.get("staged_count", 0)), int(data.get("unstaged_count", 0)), int(data.get("conflict_count", 0))]
	if dirty and current_repository_state == "idle":
		_set_status("dirty_worktree", "Merge blocked: commit or stage local changes first")
	elif current_repository_state != "idle":
		_set_status("operation_in_progress", "Repository operation in progress: " + current_repository_state)
	else:
		_set_status("ok", "Ready. Scene coloring is off until enabled manually." if not scene_color_enabled else "Ready. Scene coloring is enabled on explicit refresh.")
	_populate_conflicts(backend.conflicts())
	if scene_color_enabled and not current_diff_files.is_empty():
		_apply_scene_visualization(merge_review)

func _mode_changed(index: int) -> void:
	if base_ref_edit == null or target_ref_edit == null:
		return
	var mode := compare_mode.get_item_id(index) if compare_mode != null else MODE_HEAD_TARGET
	if mode == MODE_WORKTREE:
		base_ref_edit.text = current_branch_text
		base_ref_edit.editable = false
		target_ref_edit.text = "WORKTREE"
		target_ref_edit.editable = false
		review_button.disabled = true
		clear_review_button.disabled = true
	elif mode == MODE_HEAD_TARGET or mode == MODE_MERGE_REVIEW:
		base_ref_edit.text = current_branch_text
		base_ref_edit.editable = false
		target_ref_edit.editable = true
		if target_ref_edit.text == "WORKTREE" and target_ref != null and target_ref.item_count > 0:
			target_ref.select(0)
			target_ref_edit.text = target_ref.get_item_text(0)
		review_button.disabled = false
		clear_review_button.disabled = not merge_review
		if mode == MODE_MERGE_REVIEW:
			merge_review = true
	else:
		base_ref_edit.editable = true
		target_ref_edit.editable = true
		if target_ref_edit.text == "WORKTREE" and target_ref != null and target_ref.item_count > 0:
			target_ref.select(0)
			target_ref_edit.text = target_ref.get_item_text(0)
		review_button.disabled = true
		clear_review_button.disabled = true

func _populate_refs() -> void:
	_clear_refs()
	var first_target := ""
	for ref in backend.refs():
		if not ref is Dictionary:
			continue
		var name := str(ref.get("name", ""))
		if name.is_empty():
			continue
		if name != current_branch_text:
			target_ref.add_item(name)
			var index := target_ref.item_count - 1
			target_ref.set_item_metadata(index, ref)
			if first_target.is_empty():
				first_target = name
	if target_ref.item_count > 0:
		target_ref.select(0)
	if target_ref_edit.text.is_empty() and not first_target.is_empty():
		target_ref_edit.text = first_target
	if base_ref_edit.text.is_empty() or not base_ref_edit.editable:
		base_ref_edit.text = current_branch_text

func _clear_refs() -> void:
	if target_ref != null:
		target_ref.clear()

func _ref_picked(index: int) -> void:
	if target_ref == null or index < 0:
		return
	target_ref_edit.text = target_ref.get_item_text(index)
	_refresh_merge_enabled_from_inputs()

func _target_ref_changed(_value: String) -> void:
	_refresh_merge_enabled_from_inputs()

func _selected_target() -> String:
	if target_ref_edit != null and not target_ref_edit.text.strip_edges().is_empty():
		return target_ref_edit.text.strip_edges()
	if target_ref == null or target_ref.selected < 0:
		return ""
	return target_ref.get_item_text(target_ref.selected)

func _selected_base() -> String:
	if base_ref_edit == null:
		return current_branch_text
	var value := base_ref_edit.text.strip_edges()
	return current_branch_text if value.is_empty() else value

func _current_mode() -> int:
	return compare_mode.get_selected_id() if compare_mode != null else MODE_HEAD_TARGET

func _refresh_merge_enabled_from_inputs() -> void:
	var mode := _current_mode()
	merge_enabled = not current_branch_text.is_empty() and not _selected_target().is_empty() and current_repository_state == "idle" and (mode == MODE_HEAD_TARGET or mode == MODE_MERGE_REVIEW)
	if merge_button != null:
		merge_button.disabled = busy or not merge_enabled

func _comparison_refs() -> Dictionary:
	var mode := _current_mode()
	if mode == MODE_WORKTREE:
		return {"base": current_branch_text, "target": "WORKTREE", "mode": mode}
	return {"base": _selected_base(), "target": _selected_target(), "mode": mode}

func _merge() -> void:
	if not merge_enabled:
		_set_status("dirty_worktree", "Merge is blocked until the worktree is clean and a target ref is selected")
		return
	var target := _selected_target()
	if target.is_empty():
		_set_status("invalid_target", "Enter or select a target ref first")
		return
	_set_busy(true)
	var analysis: Dictionary = backend.analyze_merge(target)
	if not bool(analysis.get("ok", false)):
		_set_busy(false)
		_set_status(str(analysis.get("code", "merge_analysis_failed")), str(analysis.get("message", "Merge analysis failed")))
		return
	var analysis_data: Dictionary = analysis.get("data", {})
	_set_status("merge_preflight", "Merge plan: " + str(analysis_data.get("outcome", "unknown")))
	var result: Dictionary = backend.merge_ref(target)
	_set_busy(false)
	if bool(result.get("ok", false)):
		var data: Dictionary = result.get("data", {})
		merge_review = false
		current_diff_files.clear()
		_clear_scene_visualization()
		_set_status("ok", str(result.get("message", "Merge completed")) + " (" + str(data.get("outcome", "unknown")) + ")")
	else:
		_set_status(str(result.get("code", "merge_failed")), str(result.get("message", "Merge failed")))
	refresh()

func _create_merge_commit() -> void:
	if current_repository_state != "merge" or backend == null:
		_set_status("merge_commit_unavailable", "There is no pending merge commit")
		return
	var message := commit_message_edit.text.strip_edges()
	if message.is_empty():
		message = "Merge target ref"
	_set_busy(true)
	var result: Dictionary = backend.commit(message)
	_set_busy(false)
	if bool(result.get("ok", false)):
		_set_status("ok", "Merge commit created")
	else:
		_set_status(str(result.get("code", "commit_failed")), str(result.get("message", "Could not create merge commit")))
	refresh()

func _show_diff() -> void:
	var refs := _comparison_refs()
	var base := str(refs.get("base", ""))
	var target := str(refs.get("target", ""))
	if base.is_empty() or target.is_empty():
		_set_status("invalid_diff", "Enter both comparison refs or select a target")
		return
	current_base_ref = base
	current_target_ref = target
	var files: Array = []
	if target == "WORKTREE":
		files = _working_tree_files()
	else:
		var result: Dictionary = backend.diff_refs(base, target)
		if not bool(result.get("ok", false)):
			_set_status(str(result.get("code", "diff_failed")), str(result.get("message", "Diff failed")))
			return
		files = Array(result.get("data", []))
	current_diff_files = _normalize_files(files)
	_populate_files(current_diff_files)
	_set_status("ok", "Showing Diff: " + base + " -> " + target)
	if scene_color_enabled:
		_apply_scene_visualization(_current_mode() == MODE_MERGE_REVIEW or merge_review)

func _review_merge() -> void:
	if _selected_target().is_empty():
		_set_status("invalid_review", "Select or enter a target ref first")
		return
	merge_review = true
	if compare_mode != null:
		compare_mode.select(MODE_MERGE_REVIEW)
		_mode_changed(MODE_MERGE_REVIEW)
	if not scene_color_enabled:
		scene_color_toggle.button_pressed = true
		_scene_color_changed(true)
	_show_diff()

func _clear_review() -> void:
	merge_review = false
	if compare_mode != null and _current_mode() == MODE_MERGE_REVIEW:
		compare_mode.select(MODE_HEAD_TARGET)
		_mode_changed(MODE_HEAD_TARGET)
	opacity_box.visible = false
	_clear_scene_visualization()
	_set_status("review_cleared", "Temporary before/after review layers cleared")

func _fetch() -> void:
	_set_busy(true)
	var result: Dictionary = backend.fetch()
	_set_busy(false)
	_set_status(str(result.get("code", "fetch_failed")), str(result.get("message", "Fetch failed")))
	if bool(result.get("ok", false)):
		refresh()

func _populate_files(files: Array) -> void:
	file_tree.clear()
	var root := file_tree.create_item()
	for file in files:
		if not file is Dictionary:
			continue
		var item := file_tree.create_item(root)
		var path := _file_path(file)
		var status := _file_status(file)
		item.set_text(0, path)
		item.set_text(1, status)
		item.set_text(2, "binary" if bool(file.get("binary", false)) else "")
		item.set_tooltip_text(0, path)
		item.set_custom_color(1, _status_color(status))
		item.set_metadata(0, file)
	if files.is_empty():
		file_detail.text = "No changed files in the selected comparison."

func _file_selected(item: TreeItem, _column: int) -> void:
	if item == null:
		return
	var file = item.get_metadata(0)
	if not file is Dictionary:
		return
	selected_file_path = _file_path(file)
	_show_file_detail(file)

func _show_file_detail(file: Dictionary) -> void:
	var path := _file_path(file)
	var status := _file_status(file)
	var old_path := _path_value(file.get("old_file", ""))
	var new_path := _path_value(file.get("new_file", ""))
	var before := _load_compare_text(current_base_ref, old_path if not old_path.is_empty() else path)
	var after := _load_compare_text(current_target_ref, new_path if not new_path.is_empty() else path)
	var lines := ["status: " + status, "path: " + path, "", "--- " + current_base_ref + "/" + (old_path if not old_path.is_empty() else path), before, "", "+++ " + current_target_ref + "/" + (new_path if not new_path.is_empty() else path), after]
	file_detail.text = "\n".join(lines)

func _populate_conflicts(conflicts: Array) -> void:
	conflict_tree.clear()
	var root := conflict_tree.create_item()
	for conflict in conflicts:
		if not conflict is Dictionary:
			continue
		var item := conflict_tree.create_item(root)
		var path := str(conflict.get("path", ""))
		item.set_text(0, path)
		item.set_text(1, "Base/Ours/Theirs")
		item.set_text(2, "unresolved")
		item.set_custom_color(2, COLOR_DELETED)
		item.set_metadata(0, conflict)
	if conflicts.is_empty():
		selected_conflict_path = ""
		_clear_conflict_views()
		conflict_info_label.text = "No index conflicts. A clean merge can be committed explicitly below."

func _conflict_selected(item: TreeItem, _column: int) -> void:
	if item == null:
		return
	var conflict = item.get_metadata(0)
	if not conflict is Dictionary:
		return
	selected_conflict_path = str(conflict.get("path", ""))
	_load_conflict_stages(selected_conflict_path)

func _load_conflict_stages(path: String) -> void:
	var base := _conflict_blob(path, 1)
	var ours := _conflict_blob(path, 2)
	var theirs := _conflict_blob(path, 3)
	base_conflict_view.text = str(base.get("text", "[Base stage is unavailable or binary]"))
	ours_conflict_view.text = str(ours.get("text", "[Ours stage is unavailable or binary]"))
	theirs_conflict_view.text = str(theirs.get("text", "[Theirs stage is unavailable or binary]"))
	result_conflict_view.text = _read_worktree_text(path)
	var details := "Conflict: " + path
	if path.to_lower().ends_with(".tscn") and bool(base.get("ok", false)) and bool(ours.get("ok", false)) and bool(theirs.get("ok", false)):
		var analysis: Dictionary = SceneResolver.analyze(str(base.get("text", "")), str(ours.get("text", "")), str(theirs.get("text", "")))
		if bool(analysis.get("supported", false)):
			details += " | scene property conflicts: " + str(Array(analysis.get("conflicts", [])).size())
		else:
			details += " | scene parser fallback: " + str(analysis.get("diagnostic", "unsupported"))
	conflict_info_label.text = details + ". Choose a stage or edit Result, then stage it."
	var auto := SceneResolver.auto_merge_text(str(base.get("text", "")), str(ours.get("text", "")), str(theirs.get("text", "")))
	if bool(auto.get("ok", false)):
		result_conflict_view.text = str(auto.get("text", ""))
	_set_conflict_buttons(bool(base.get("ok", false)), bool(ours.get("ok", false)), bool(theirs.get("ok", false)))

func _conflict_blob(path: String, stage: int) -> Dictionary:
	if backend == null:
		return {"ok": false, "text": ""}
	return backend.conflict_blob(path, stage)

func _take_base() -> void:
	_take_conflict_text(base_conflict_view.text)

func _take_ours() -> void:
	_take_conflict_text(ours_conflict_view.text)

func _take_theirs() -> void:
	_take_conflict_text(theirs_conflict_view.text)

func _take_conflict_text(value: String) -> void:
	if selected_conflict_path.is_empty():
		return
	result_conflict_view.text = value

func _stage_conflict() -> void:
	if selected_conflict_path.is_empty():
		_set_status("no_conflict_selected", "Select a conflict first")
		return
	_set_busy(true)
	var result: Dictionary = backend.write_and_stage(selected_conflict_path, result_conflict_view.text)
	_set_busy(false)
	if bool(result.get("ok", false)):
		_set_status("ok", "Resolved and staged " + selected_conflict_path)
	else:
		_set_status(str(result.get("code", "stage_failed")), str(result.get("message", "Could not stage conflict result")))
	refresh()

func _set_conflict_buttons(has_base: bool, has_ours: bool, has_theirs: bool) -> void:
	take_base_button.disabled = not has_base
	take_ours_button.disabled = not has_ours
	take_theirs_button.disabled = not has_theirs
	stage_conflict_button.disabled = selected_conflict_path.is_empty()

func _clear_conflict_views() -> void:
	if base_conflict_view == null:
		return
	base_conflict_view.text = ""
	ours_conflict_view.text = ""
	theirs_conflict_view.text = ""
	result_conflict_view.text = ""
	_set_conflict_buttons(false, false, false)

func _normalize_files(files: Array) -> Array:
	var result: Array = []
	for file in files:
		if not file is Dictionary:
			continue
		var normalized: Dictionary = file.duplicate(true)
		normalized["status"] = _file_status(normalized)
		normalized["path"] = _file_path(normalized)
		result.append(normalized)
	return result

func _working_tree_files() -> Array:
	if backend == null or not backend.has_method("modified_files"):
		return []
	return _normalize_files(backend.modified_files())

func _file_path(file: Dictionary) -> String:
	var new_path := _path_value(file.get("new_file", ""))
	if not new_path.is_empty():
		return new_path
	var old_path := _path_value(file.get("old_file", ""))
	if not old_path.is_empty():
		return old_path
	return _path_value(file.get("file_path", file.get("path", "")))

func _path_value(value) -> String:
	if value is Dictionary:
		return str(value.get("path", value.get("file_path", "")))
	return str(value)

func _file_status(file: Dictionary) -> String:
	var explicit := str(file.get("status", "")).to_upper()
	if explicit in ["ADDED", "DELETED", "MODIFIED", "RENAMED", "COPIED", "TYPE_CHANGED", "CONFLICT"]:
		return explicit
	if file.has("change_type") and file.get("change_type") is int:
		match int(file.get("change_type")):
			0:
				return "ADDED"
			2:
				return "RENAMED"
			3:
				return "DELETED"
			4:
				return "TYPE_CHANGED"
			5:
				return "CONFLICT"
	var change_type := str(file.get("change_type", file.get("type", ""))).to_lower()
	if change_type.contains("new") or change_type.contains("add"):
		return "ADDED"
	if change_type.contains("delete") or change_type.contains("remove"):
		return "DELETED"
	if change_type.contains("rename"):
		return "RENAMED"
	if change_type.contains("type"):
		return "TYPE_CHANGED"
	var old_path := _path_value(file.get("old_file", ""))
	var new_path := _path_value(file.get("new_file", ""))
	if old_path.is_empty() and not new_path.is_empty():
		return "ADDED"
	if new_path.is_empty() and not old_path.is_empty():
		return "DELETED"
	return "MODIFIED"

func _status_color(status: String) -> Color:
	match status.to_upper():
		"ADDED":
			return COLOR_ADDED
		"DELETED", "CONFLICT":
			return COLOR_DELETED
		_:
			return COLOR_MODIFIED

func _scene_color_changed(enabled: bool) -> void:
	scene_color_enabled = enabled
	if overlay_renderer != null:
		overlay_renderer.set_enabled(enabled)
	if not enabled:
		_clear_scene_visualization()
		_set_status("scene_color_disabled", "Scene Diff coloring disabled; temporary review layers cleared")
		return
	_set_status("scene_color_enabled", "Scene Diff coloring enabled; press Diff or Refresh to scan the edited scene")
	if not current_diff_files.is_empty():
		_apply_scene_visualization(merge_review)

func _apply_scene_visualization(review: bool) -> void:
	if not scene_color_enabled:
		return
	var edited_root := _edited_scene_root()
	if edited_root == null:
		_clear_scene_visualization()
		_set_scene_info("No edited scene is open")
		return
	var scene_path := _edited_scene_relative_path(edited_root)
	current_scene_path = scene_path
	var scene_file: Dictionary = {}
	for file in current_diff_files:
		if _normalize_repo_path(_file_path(file)) == scene_path and scene_path.to_lower().ends_with(".tscn"):
			scene_file = file
			break
	if scene_file.is_empty():
		_clear_scene_visualization()
		_set_scene_info("The edited scene has no file-level change in this comparison")
		return
	var path := _file_path(scene_file)
	var old_path := _path_value(scene_file.get("old_file", ""))
	var new_path := _path_value(scene_file.get("new_file", ""))
	var before := _load_compare_text(current_base_ref, old_path if not old_path.is_empty() else path)
	var after := _load_compare_text(current_target_ref, new_path if not new_path.is_empty() else path)
	if before.begins_with("[binary") or after.begins_with("[binary"):
		_clear_scene_visualization()
		_set_scene_info("Scene is binary or unavailable; showing file-level Diff only")
		return
	var result: Dictionary = SceneDiff.compare_text(before, after)
	if not bool(result.get("supported", false)):
		_clear_scene_visualization()
		_set_scene_info("Scene structural Diff unavailable: " + str(result.get("diagnostic", "unsupported")))
		return
	current_scene_entries = Array(result.get("entries", []))
	_populate_scene_entries(current_scene_entries)
	tree_color_adapter.apply(current_scene_entries, scene_diff_tree)
	_cleanup_snapshot_roots()
	var snapshot_id := current_base_ref + "__" + current_target_ref
	var before_result: Dictionary = snapshot_cache.load_scene(snapshot_id, scene_path, before, "before")
	var after_result: Dictionary = snapshot_cache.load_scene(snapshot_id, scene_path, after, "after")
	before_snapshot_root = _instantiate_snapshot(before_result)
	after_snapshot_root = _instantiate_snapshot(after_result)
	overlay_renderer.before_opacity = float(before_opacity_slider.value) if before_opacity_slider != null else 0.5
	overlay_renderer.after_opacity = float(after_opacity_slider.value) if after_opacity_slider != null else 0.5
	overlay_renderer.set_enabled(true)
	overlay_renderer.apply_diff(edited_root, current_scene_entries, before_snapshot_root, after_snapshot_root, review)
	opacity_box.visible = review
	_set_scene_info("%d scene node changes: green added, yellow modified, red deleted" % current_scene_entries.size())

func _populate_scene_entries(entries: Array) -> void:
	scene_diff_tree.clear()
	var root := scene_diff_tree.create_item()
	for entry in entries:
		if not entry is Dictionary:
			continue
		var item := scene_diff_tree.create_item(root)
		var status := str(entry.get("status", "MODIFIED"))
		item.set_text(0, str(entry.get("path", "")))
		item.set_text(1, status)
		item.set_text(2, ", ".join(Array(entry.get("changed_properties", []))))
		item.set_custom_color(1, _status_color(status))
		item.set_metadata(0, entry)

func _clear_scene_visualization() -> void:
	current_scene_entries.clear()
	if tree_color_adapter != null:
		tree_color_adapter.clear()
	if scene_diff_tree != null:
		scene_diff_tree.clear()
	if overlay_renderer != null:
		overlay_renderer.set_enabled(false)
		overlay_renderer.detach()
	_cleanup_snapshot_roots()
	if snapshot_cache != null:
		snapshot_cache.clear()
	if opacity_box != null:
		opacity_box.visible = false

func _edited_scene_root() -> Node:
	if editor_interface == null or not editor_interface.has_method("get_edited_scene_root"):
		return null
	return editor_interface.get_edited_scene_root()

func _edited_scene_relative_path(root: Node) -> String:
	if root == null:
		return ""
	var path := str(root.scene_file_path)
	if path.begins_with("res://"):
		return _normalize_repo_path(path.substr(6))
	return _normalize_repo_path(path)

func _normalize_repo_path(path: String) -> String:
	var value := path.replace("\\", "/")
	return value.trim_prefix("res://")

func _load_compare_text(ref_name: String, path: String) -> String:
	if path.is_empty():
		return ""
	if ref_name == "WORKTREE":
		return _read_worktree_text(path)
	if backend == null:
		return ""
	var result: Dictionary = backend.blob(ref_name, path)
	if not bool(result.get("ok", false)):
		return ""
	if bool(result.get("binary", false)):
		return "[binary content]"
	var data: Dictionary = result.get("data", {})
	return str(data.get("text", ""))

func _read_worktree_text(path: String) -> String:
	var absolute := str(backend.project_path).path_join(_normalize_repo_path(path)) if backend != null else ""
	var file := FileAccess.open(absolute, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text

func _instantiate_snapshot(result: Dictionary) -> Node:
	if not bool(result.get("ok", false)):
		return null
	var packed = result.get("scene")
	if packed == null or not packed is PackedScene:
		return null
	var root: Node = packed.instantiate()
	if root == null:
		return null
	_disable_snapshot_behavior(root)
	return root

func _disable_snapshot_behavior(node: Node) -> void:
	node.owner = null
	node.process_mode = Node.PROCESS_MODE_DISABLED
	if node.get_script() != null:
		node.set_script(null)
	if node is CollisionObject3D:
		node.collision_layer = 0
		node.collision_mask = 0
	for child in node.get_children():
		_disable_snapshot_behavior(child)

func _cleanup_snapshot_roots() -> void:
	if is_instance_valid(before_snapshot_root):
		before_snapshot_root.free()
	if is_instance_valid(after_snapshot_root):
		after_snapshot_root.free()
	before_snapshot_root = null
	after_snapshot_root = null

func _before_opacity_changed(value: float) -> void:
	if overlay_renderer != null:
		overlay_renderer.before_opacity = value
		_reapply_overlay()

func _after_opacity_changed(value: float) -> void:
	if overlay_renderer != null:
		overlay_renderer.after_opacity = value
		_reapply_overlay()

func _reapply_overlay() -> void:
	if not scene_color_enabled or not merge_review:
		return
	var root := _edited_scene_root()
	if root != null:
		overlay_renderer.apply_diff(root, current_scene_entries, before_snapshot_root, after_snapshot_root, true)

func _set_scene_info(message: String) -> void:
	if scene_info_label != null:
		scene_info_label.text = message

func _set_busy(value: bool) -> void:
	busy = value
	if refresh_button == null:
		return
	refresh_button.disabled = value
	fetch_button.disabled = value
	diff_button.disabled = value
	review_button.disabled = value or _current_mode() == MODE_REF_REF or _current_mode() == MODE_WORKTREE
	clear_review_button.disabled = value or not merge_review
	merge_button.disabled = value or not merge_enabled
	merge_commit_button.disabled = value or current_repository_state != "merge"
	target_ref.disabled = value
	base_ref_edit.editable = not value and _current_mode() == MODE_REF_REF
	target_ref_edit.editable = not value and _current_mode() != MODE_WORKTREE

func _set_status(code: String, message: String) -> void:
	status_code = code
	if status_label != null:
		status_label.text = message

func cleanup() -> void:
	scene_color_enabled = false
	if tree_color_adapter != null:
		tree_color_adapter.clear()
	if overlay_renderer != null:
		overlay_renderer.detach()
	_cleanup_snapshot_roots()
	if snapshot_cache != null:
		snapshot_cache.clear()
