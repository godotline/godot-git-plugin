# Git Collaboration Diff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Godot 4.7 bottom collaboration panel backed by libgit2, with safe branch merge, arbitrary ref/commit Diff, conflict resolution, and opt-in scene visualization.

**Architecture:** `GitPlugin` remains the repository authority and exposes structured collaboration methods through GDExtension. A Godot 4.7 `EditorPlugin` consumes that API, owns the bottom panel, parses scene snapshots, resolves text/scene conflicts, and creates temporary editor-only review overlays.

**Tech Stack:** C++17, libgit2, godot-cpp/GDExtension, Godot 4.7 GDScript, SCons, gdmcp, headless Godot fixture tests.

**Workspace Rule:** Do not create Git commits unless the user explicitly requests them. Each task ends with a diff/test checkpoint instead.

**Execution Prerequisites:** The current checkout has uninitialized submodules, no `scons` or `godot`/`godot4` executable in `PATH`, and no reachable gdmcp service. Before Task 1 GREEN verification, initialize the pinned submodules with `git submodule update --init --recursive`, provide the user's Godot 4.7 editor binary, install or expose SCons, and start the editor-side gdmcp service. If a prerequisite remains unavailable, record that exact validation gap and do not claim the corresponding build/editor/visual check passed.

---

## File Map

- Modify `addons/godot-git-plugin/git_plugin.gdextension`: set the 4.7 compatibility target.
- Create `addons/godot-git-plugin/plugin.cfg`: register the editor addon.
- Create `addons/godot-git-plugin/git_collaboration_plugin.gd`: own addon lifecycle and bottom-panel registration.
- Create `addons/godot-git-plugin/ui/git_collaboration_dock.gd`: build and update the collaboration UI.
- Create `addons/godot-git-plugin/backend/git_backend_adapter.gd`: isolate the C++ API and provide a fakeable GDScript boundary.
- Create `addons/godot-git-plugin/scene/scene_diff_model.gd`: parse and compare `.tscn` structure and properties.
- Create `addons/godot-git-plugin/scene/scene_conflict_resolver.gd`: perform three-way scene decisions and deterministic serialization.
- Create `addons/godot-git-plugin/scene/scene_snapshot_cache.gd`: materialize ref snapshots under `user://` and invalidate them.
- Create `addons/godot-git-plugin/scene/scene_overlay_renderer.gd`: create and clear editor-only visual review layers.
- Create `addons/godot-git-plugin/scene/scene_tree_color_adapter.gd`: color the Godot 4.7 SceneTree when supported and drive the fallback Diff Tree otherwise.
- Modify `godot-git-plugin/src/git_plugin.h`: declare script-facing collaboration methods and shared merge helpers.
- Modify `godot-git-plugin/src/git_plugin.cpp`: bind collaboration methods and route existing pull logic through shared helpers.
- Create `godot-git-plugin/src/git_collaboration.cpp`: implement repository state, refs, arbitrary tree Diff, blob access, merge, and conflicts.
- Create `tests/godot_harness/project.godot`: minimal 4.7 test project.
- Create `tests/godot_harness/run_tests.gd`: deterministic test runner.
- Create `tests/godot_harness/support/fake_backend.gd`: UI/backend test double.
- Create `tests/godot_harness/support/git_fixture.gd`: create isolated Git repositories for native integration tests.
- Create focused test scripts under `tests/godot_harness/cases/` and fixture scenes under `tests/godot_harness/fixtures/`.
- Create `tests/run_godot_tests.sh`: stage the addon into a temporary project and run headless tests without polluting the repository.
- Modify `README.md`: document activation, merge safeguards, Diff modes, scene coloring, and limitations.

## Task 1: Godot 4.7 Harness and Bound API Contract

**Files:**
- Create: `tests/godot_harness/project.godot`
- Create: `tests/godot_harness/run_tests.gd`
- Create: `tests/godot_harness/cases/test_backend_contract.gd`
- Create: `tests/run_godot_tests.sh`
- Modify: `addons/godot-git-plugin/git_plugin.gdextension`
- Modify: `godot-git-plugin/src/git_plugin.h`
- Modify: `godot-git-plugin/src/git_plugin.cpp`

- [ ] **Step 1: Write the failing backend-contract test**

```gdscript
func run() -> void:
	assert_true(ClassDB.class_exists("GitPlugin"), "GitPlugin must be registered")
	var backend := ClassDB.instantiate("GitPlugin")
	for method in [
		"collaboration_initialize",
		"collaboration_get_repository_state",
		"collaboration_get_refs",
		"collaboration_diff_refs",
		"collaboration_get_blob",
		"collaboration_analyze_merge",
		"collaboration_merge_ref",
		"collaboration_get_conflicts",
		"collaboration_get_conflict_blob",
		"collaboration_write_and_stage",
	]:
		assert_true(backend.has_method(method), "Missing method: " + method)
```

- [ ] **Step 2: Run the harness and verify RED**

Run: `bash tests/run_godot_tests.sh test_backend_contract`

Expected: FAIL because the collaboration methods are not bound.

- [ ] **Step 3: Declare and bind the minimal API**

Add these public signatures to `GitPlugin` and bind them in `_bind_methods()`:

```cpp
godot::Dictionary collaboration_initialize(const godot::String &project_path);
godot::Dictionary collaboration_get_repository_state();
godot::TypedArray<godot::Dictionary> collaboration_get_refs();
godot::Dictionary collaboration_diff_refs(const godot::String &base_ref, const godot::String &target_ref, const godot::String &path_filter);
godot::Dictionary collaboration_get_blob(const godot::String &ref_name, const godot::String &path);
godot::Dictionary collaboration_analyze_merge(const godot::String &target_ref);
godot::Dictionary collaboration_merge_ref(const godot::String &target_ref);
godot::TypedArray<godot::Dictionary> collaboration_get_conflicts();
godot::Dictionary collaboration_get_conflict_blob(const godot::String &path, int32_t stage);
godot::Dictionary collaboration_write_and_stage(const godot::String &path, const godot::String &content);
godot::Dictionary collaboration_result(bool ok, const godot::String &code, const godot::String &message, const godot::Variant &data = godot::Variant()) const;
```

Each unimplemented method returns `{"ok": false, "code": "not_implemented", "message": "...", "data": null}` so the contract test can distinguish method presence from behavior.

- [ ] **Step 4: Build and verify GREEN**

Run: `scons platform=linux target=editor`

Run: `bash tests/run_godot_tests.sh test_backend_contract`

Expected: native build exits 0 and the contract test passes.

- [ ] **Step 5: Checkpoint**

Run: `git diff --check`

Inspect: `git diff -- addons/godot-git-plugin/git_plugin.gdextension godot-git-plugin/src/git_plugin.h godot-git-plugin/src/git_plugin.cpp tests/`

## Task 2: Repository State and Ref Discovery

**Files:**
- Create: `godot-git-plugin/src/git_collaboration.cpp`
- Create: `tests/godot_harness/support/git_fixture.gd`
- Create: `tests/godot_harness/cases/test_repository_state.gd`
- Modify: `godot-git-plugin/src/git_plugin.h`

- [ ] **Step 1: Write failing fixture tests**

The fixture creates `main`, `feature`, `refs/remotes/origin/main`, tag `v1`, one staged change, and one unstaged change. Assert this shape:

```gdscript
var state: Dictionary = backend.collaboration_get_repository_state()
assert_eq(state.code, "ok")
assert_eq(state.data.current_branch, "main")
assert_true(state.data.dirty)
assert_eq(state.data.staged_count, 1)
assert_eq(state.data.unstaged_count, 1)

var refs: Array = backend.collaboration_get_refs()
assert_ref(refs, "main", "local")
assert_ref(refs, "origin/main", "remote")
assert_ref(refs, "v1", "tag")
```

- [ ] **Step 2: Verify RED**

Run: `bash tests/run_godot_tests.sh test_repository_state`

Expected: FAIL with `not_implemented`.

- [ ] **Step 3: Implement state and refs**

Use `git_repository_state`, `git_repository_head`, `git_status_list_new`, `git_branch_iterator_new`, and `git_tag_list`. Return stable dictionaries with `current_branch`, `detached`, `dirty`, staged/unstaged/conflict counts, repository state, and ref name/type/OID/summary.

- [ ] **Step 4: Verify GREEN and regressions**

Run: `bash tests/run_godot_tests.sh test_repository_state`

Run: `bash tests/run_godot_tests.sh`

Expected: all harness tests pass.

- [ ] **Step 5: Checkpoint**

Run: `git diff --check`

## Task 3: Arbitrary Ref/Commit Diff and Blob Access

**Files:**
- Create: `tests/godot_harness/cases/test_ref_diff.gd`
- Modify: `godot-git-plugin/src/git_collaboration.cpp`
- Modify: `godot-git-plugin/src/git_plugin.cpp`

- [ ] **Step 1: Write failing tests for two commits**

```gdscript
var result: Dictionary = backend.collaboration_diff_refs(base_oid, target_oid, "")
assert_true(result.ok)
assert_file_status(result.data.files, "added.tscn", "added")
assert_file_status(result.data.files, "renamed.gd", "renamed")
assert_file_status(result.data.files, "deleted.txt", "deleted")

var blob: Dictionary = backend.collaboration_get_blob(base_oid, "level.tscn")
assert_true(blob.ok)
assert_eq(blob.data.binary, false)
assert_contains(blob.data.text, "[gd_scene")
```

- [ ] **Step 2: Verify RED**

Run: `bash tests/run_godot_tests.sh test_ref_diff`

Expected: FAIL with `not_implemented`.

- [ ] **Step 3: Implement tree-to-tree Diff and blob lookup**

Resolve each ref with `git_revparse_single`, peel commits to trees, call `git_diff_tree_to_tree`, enable rename detection with `git_diff_find_similar`, and reuse `_parse_diff` for hunks. Blob access walks the tree path, returns UTF-8 text when valid, and returns `binary: true` without fabricated text otherwise.

- [ ] **Step 4: Route commit-vs-parent through the shared helper**

Keep `_get_diff(..., TREE_AREA_COMMIT)` behavior unchanged by resolving the selected commit and its requested/default parent before invoking the shared tree Diff path.

- [ ] **Step 5: Verify GREEN**

Run: `bash tests/run_godot_tests.sh test_ref_diff`

Run: `bash tests/run_godot_tests.sh`

Expected: arbitrary refs and existing VCS Diff tests pass.

## Task 4: Merge Preflight, Execution, and Conflict Stages

**Files:**
- Create: `tests/godot_harness/cases/test_merge_workflow.gd`
- Modify: `godot-git-plugin/src/git_collaboration.cpp`
- Modify: `godot-git-plugin/src/git_plugin.cpp`
- Modify: `godot-git-plugin/src/git_plugin.h`

- [ ] **Step 1: Write failing merge tests**

Cover dirty rejection without changed file hashes, already-up-to-date, fast-forward, normal clean merge, and a text conflict:

```gdscript
var before := fixture.hash_worktree()
var blocked: Dictionary = backend.collaboration_merge_ref("feature")
assert_eq(blocked.code, "dirty_worktree")
assert_eq(fixture.hash_worktree(), before)

fixture.reset_clean()
var merged: Dictionary = backend.collaboration_merge_ref("feature")
assert_true(merged.ok)
assert_in(merged.data.outcome, ["fast_forward", "clean_merge", "conflicts", "up_to_date"])
```

- [ ] **Step 2: Verify RED**

Run: `bash tests/run_godot_tests.sh test_merge_workflow`

Expected: FAIL with `not_implemented`.

- [ ] **Step 3: Implement merge analysis and execution**

Preflight rejects detached HEAD, the current ref, missing targets, dirty index/worktree, and non-idle repository state. Use `git_merge_analysis`; fast-forward uses safe checkout plus reference update; normal merge uses diff3/minimal flags and leaves merge state/index for an explicit commit.

- [ ] **Step 4: Implement conflict stage access and write/stage**

Enumerate conflicts with `git_index_conflict_iterator`. Return stage 1 Base, stage 2 Ours, and stage 3 Theirs blobs. `collaboration_write_and_stage` rejects absolute/escaping paths, writes below `repo_project_path`, adds the path to the index, and verifies conflict removal.

- [ ] **Step 5: Reuse the helper from `_pull`**

Preserve existing remote fetch behavior, then pass the fetched commit into the shared merge implementation so pull and the collaboration panel have identical merge semantics.

- [ ] **Step 6: Verify GREEN**

Run: `bash tests/run_godot_tests.sh test_merge_workflow`

Run: `bash tests/run_godot_tests.sh`

Expected: all merge outcomes pass and dirty rejection preserves hashes.

## Task 5: Addon Lifecycle, Backend Adapter, and Bottom Panel

**Files:**
- Create: `addons/godot-git-plugin/plugin.cfg`
- Create: `addons/godot-git-plugin/git_collaboration_plugin.gd`
- Create: `addons/godot-git-plugin/backend/git_backend_adapter.gd`
- Create: `addons/godot-git-plugin/ui/git_collaboration_dock.gd`
- Create: `tests/godot_harness/support/fake_backend.gd`
- Create: `tests/godot_harness/cases/test_dock_state.gd`

- [ ] **Step 1: Write a failing UI-state test with a fake backend**

```gdscript
var dock := GitCollaborationDock.new()
dock.backend = FakeBackend.clean_repo()
dock.refresh()
assert_eq(dock.current_branch_text, "feature/scene")
assert_true(dock.merge_enabled)

dock.backend = FakeBackend.dirty_repo()
dock.refresh()
assert_false(dock.merge_enabled)
assert_eq(dock.status_code, "dirty_worktree")
```

- [ ] **Step 2: Verify RED**

Run: `bash tests/run_godot_tests.sh test_dock_state`

Expected: FAIL because the addon classes do not exist.

- [ ] **Step 3: Implement addon registration and backend isolation**

`GitCollaborationPlugin` obtains the active `GitPlugin`, wraps it with `GitBackendAdapter`, registers the bottom panel, and clears plugin-owned state in `_exit_tree`. The adapter exposes typed methods but never parses repository files itself.

- [ ] **Step 4: Implement the work-focused panel**

Use compact Godot controls: ref selectors, icon buttons for Refresh/Fetch/open/reveal/copy, text buttons for Merge and Resolve, conflict count, ahead/behind summary, file list, Diff view, and an off-by-default scene-color toggle. Disable mutating actions while busy or blocked.

- [ ] **Step 5: Verify GREEN**

Run: `bash tests/run_godot_tests.sh test_dock_state`

Run: `gdmcp --json scripts validate res://addons/godot-git-plugin/git_collaboration_plugin.gd`

Expected: state tests pass; exact script validation reports zero errors.

## Task 6: Scene Text Model and Semantic Diff

**Files:**
- Create: `addons/godot-git-plugin/scene/scene_diff_model.gd`
- Create: `tests/godot_harness/fixtures/base_scene.tscn`
- Create: `tests/godot_harness/fixtures/target_scene.tscn`
- Create: `tests/godot_harness/cases/test_scene_diff_model.gd`

- [ ] **Step 1: Write failing semantic tests**

```gdscript
var diff := SceneDiffModel.compare_text(BASE_SCENE, TARGET_SCENE)
assert_status(diff, NodePath("Player"), "ADDED")
assert_status(diff, NodePath("OldLight"), "DELETED")
assert_status(diff, NodePath("CameraRig"), "MODIFIED")
assert_property(diff, NodePath("CameraRig"), "transform")
assert_status(diff, NodePath("Environment/Sun"), "MOVED")
```

- [ ] **Step 2: Verify RED**

Run: `bash tests/run_godot_tests.sh test_scene_diff_model`

Expected: FAIL because `SceneDiffModel` does not exist.

- [ ] **Step 3: Implement parsing and comparison**

Parse `.tscn` sections without executing scripts. Key nodes by normalized relative path, preserve raw property expressions, exclude serialization-only `load_steps`, compare node type/parent/properties/groups/connections/resources, and infer a move only when one deleted and one added node have a unique matching type/property fingerprint.

- [ ] **Step 4: Add malformed/binary fallback tests**

Assert malformed scene text returns `supported: false`, a stable diagnostic, and raw Diff availability rather than a partial semantic model.

- [ ] **Step 5: Verify GREEN**

Run: `bash tests/run_godot_tests.sh test_scene_diff_model`

Expected: all statuses and fallback behavior pass.

## Task 7: Three-Way Text and Scene Conflict Resolution

**Files:**
- Create: `addons/godot-git-plugin/scene/scene_conflict_resolver.gd`
- Create: `tests/godot_harness/cases/test_scene_conflict_resolver.gd`
- Modify: `addons/godot-git-plugin/ui/git_collaboration_dock.gd`

- [ ] **Step 1: Write failing three-way tests**

```gdscript
var result := SceneConflictResolver.merge(BASE, OURS, THEIRS)
assert_eq(result.nodes[NodePath("Camera")].properties["fov"].resolution, "theirs")
assert_eq(result.nodes[NodePath("Player")].properties["speed"].resolution, "conflict")
assert_true(result.requires_user_choice)
```

- [ ] **Step 2: Verify RED**

Run: `bash tests/run_godot_tests.sh test_scene_conflict_resolver`

Expected: FAIL because the resolver does not exist.

- [ ] **Step 3: Implement deterministic three-way decisions**

If Ours equals Base, select Theirs; if Theirs equals Base, select Ours; if Ours equals Theirs, select either; otherwise create an unresolved node/property choice. Preserve original section order and raw expressions when serializing.

- [ ] **Step 4: Implement whole-file fallback and UI actions**

For unsupported scenes, offer Base/Ours/Theirs and manual result text. Stage only after the backend successfully writes the selected result and reports the path no longer conflicted.

- [ ] **Step 5: Verify GREEN**

Run: `bash tests/run_godot_tests.sh test_scene_conflict_resolver`

Run: `bash tests/run_godot_tests.sh test_dock_state`

Expected: semantic choices, fallback, and staging state pass.

## Task 8: Snapshot Cache and Manual Scene Overlays

**Files:**
- Create: `addons/godot-git-plugin/scene/scene_snapshot_cache.gd`
- Create: `addons/godot-git-plugin/scene/scene_overlay_renderer.gd`
- Create: `tests/godot_harness/cases/test_scene_overlay.gd`
- Modify: `addons/godot-git-plugin/ui/git_collaboration_dock.gd`

- [ ] **Step 1: Write the off-state regression test**

```gdscript
var renderer := SceneOverlayRenderer.new()
renderer.set_enabled(false)
renderer.apply_diff(edited_root, diff, before_scene, after_scene)
assert_eq(renderer.overlay_count(), 0)
assert_eq(snapshot_cache.load_count, 0)
```

Add enabled-state assertions for green added overlays, yellow modified overlays, red deleted ghosts, and independent before/after opacity.

- [ ] **Step 2: Verify RED**

Run: `bash tests/run_godot_tests.sh test_scene_overlay`

Expected: FAIL because cache and renderer do not exist.

- [ ] **Step 3: Implement snapshot caching**

Store only plugin-owned files below `user://godot-git-plugin/snapshots/<oid>/`. Key cache entries by base/target OID, scene path, worktree signature, and mode. Invalidate on ref/worktree change and clear all loaded resources when coloring is disabled.

- [ ] **Step 4: Implement editor-only overlays**

Duplicate only renderable geometry needed for review; never attach user scripts; set `owner = null`, disable processing and collisions, and apply transparent status materials. Normal Diff shows deleted ghosts; merge review shows separate before and after roots with opacity controls. Unsupported geometry receives a colored bounds gizmo instead of being silently omitted.

- [ ] **Step 5: Verify GREEN**

Run: `bash tests/run_godot_tests.sh test_scene_overlay`

Expected: off state has zero loads/overlays; enabled state has exact status counts and cleanup returns to zero.

## Task 9: SceneTree Coloring Adapter and Full Panel Integration

**Files:**
- Create: `addons/godot-git-plugin/scene/scene_tree_color_adapter.gd`
- Create: `tests/godot_harness/cases/test_scene_tree_color_adapter.gd`
- Modify: `addons/godot-git-plugin/ui/git_collaboration_dock.gd`
- Modify: `addons/godot-git-plugin/git_collaboration_plugin.gd`

- [ ] **Step 1: Write failing adapter tests**

Assert `ADDED`, `MODIFIED`, `DELETED`, `MOVED`, and `CONFLICT` map to color plus text/icon, selection focuses the corresponding edited node, and unsupported editor-tree discovery activates the fallback Diff Tree.

- [ ] **Step 2: Verify RED**

Run: `bash tests/run_godot_tests.sh test_scene_tree_color_adapter`

Expected: FAIL because the adapter does not exist.

- [ ] **Step 3: Implement feature-detected coloring**

Locate the Godot 4.7 SceneTree through public editor access first. Guard every internal-tree fallback with class/method checks, record original item colors before modification, and restore them on refresh/disable/exit. The fallback tree mirrors node paths and status actions without touching scene data.

- [ ] **Step 4: Connect Diff modes and collaboration actions**

Wire working-tree, arbitrary ref/commit, merge-base, and conflict comparisons to the same file/scene model. Add explicit Refresh, Fetch, open, reveal, copy-path, Stage, Resolve, Merge Commit, cache clear, and scene-color actions.

- [ ] **Step 5: Verify GREEN**

Run: `bash tests/run_godot_tests.sh`

Expected: all backend, model, resolver, overlay, adapter, and dock tests pass.

## Task 10: Editor/Visual Verification and Documentation

**Files:**
- Modify: `README.md`
- Create: `tests/godot_harness/fixtures/review_scene.tscn`
- Create: `tests/godot_harness/fixtures/review_scene_base.tscn`

- [ ] **Step 1: Document the workflow and safety contract**

Document Godot 4.7, addon activation, explicit Fetch, dirty-worktree merge blocking, arbitrary commit selection, conflict resolution, scene-color default-off behavior, status colors, cache path, and unsupported-scene fallback.

- [ ] **Step 2: Run fresh native and headless verification**

Run: `scons platform=linux target=editor`

Run: `bash tests/run_godot_tests.sh`

Expected: build exits 0; test runner reports zero failures.

- [ ] **Step 3: Validate every addon script**

Run `gdmcp --json scripts validate <res://path>` for each GDScript under `addons/godot-git-plugin/`.

Expected: every script reports zero errors and zero warnings.

- [ ] **Step 4: Verify editor states with gdmcp**

Run: `gdmcp --json doctor`

Run: `gdmcp --json editor state`

Open the fixture project, confirm the bottom panel node/control hierarchy, exercise dirty merge rejection and an isolated merge conflict, then inspect conflict rows and repository state.

- [ ] **Step 5: Verify visuals with coloring off and on**

Capture desktop screenshots for: panel idle state, scene color off, scene color on with green/yellow/red entries, deleted ghost, and merge review with before/after opacity. Assert the overlay root counts and relevant material colors in addition to visually checking non-blank rendering and no overlap.

- [ ] **Step 6: Run final repository checks**

Run: `git diff --check`

Run: `git status --short`

Run: `rg -n "TODO|TBD|not_implemented" addons/godot-git-plugin godot-git-plugin/src tests README.md`

Expected: no whitespace errors, no generated snapshots/cache files, and no production placeholders.
