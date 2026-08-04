# Godot Git Collaboration Diff Design

**Date:** 2026-08-03

**Target:** Godot 4.7. This feature does not preserve Godot 4.3 compatibility.

## Goal

Add a Godot editor collaboration workflow to the existing libgit2-backed VCS extension. The workflow provides a bottom collaboration panel, direct merge of a selected target ref into the current checkout branch, arbitrary commit-to-commit Diff, explicit conflict resolution, and opt-in scene visualization for added, deleted, modified, and conflicting nodes.

## Confirmed Decisions

- The primary UI is a collapsible bottom collaboration panel.
- The implementation is a hybrid: C++ owns Git truth and the Godot 4.7 addon owns editor UI and scene visualization.
- Scene Diff supports both working tree vs current `HEAD` and arbitrary ref/commit-to-ref/commit comparison.
- Diff and merge views show deleted nodes as read-only red ghost overlays.
- Merge review shows before and after scene content as semi-transparent layers with opacity control.
- Scene coloring is off by default and must be explicitly enabled. Turning it off stops scene scanning and removes all temporary review objects.
- A dirty worktree blocks merge. The addon never auto-stashes, auto-commits, or auto-pushes.
- Text conflicts use Base/Ours/Theirs plus manual result editing. `.tscn` conflicts use node/property resolution when parsing is safe and fall back to whole-file three-way resolution otherwise.
- Clean merges leave the user in control of creating the merge commit.
- Godot 4.7 editor APIs are the compatibility target. Scene-tree coloring is isolated behind a feature-detected adapter with an addon-owned colored Diff Tree fallback.

## Scope

### Git workflow

The panel exposes the current branch, target branch/ref, worktree state, changed-file count, conflict count, and recent commit information. Target refs may be local branches, remote-tracking refs, tags, or commits already present in the repository. Fetch remains an explicit action and merge never performs hidden network access.

Merge preflight checks repository availability, a named current branch, a different existing target ref, a clean index and worktree, and the absence of an unfinished merge/rebase/cherry-pick state. A successful preflight executes the selected merge directly and reports one of these results:

- Fast-forward: the current branch moves to the target and no merge state remains.
- Clean merge: the index and worktree contain the merged result and the panel offers a merge commit action.
- Conflicts: Git stage 1/2/3 entries remain available and the panel switches to conflict review.
- Already up to date: no worktree change is made.
- Rejected: the operation returns a stable error code and leaves the repository untouched where libgit2 permits it.

### Diff modes

The ref selectors support these comparison modes:

1. Working tree vs current `HEAD` for local edits.
2. Current checkout `HEAD` vs a selected target ref.
3. Any commit/ref A vs any commit/ref B.
4. Merge review using `merge-base(current, target) -> target` for target-only changes.
5. Conflict review using Base/Ours/Theirs stage content.

An arbitrary commit comparison is symmetric at the UI level: the left selector is the base snapshot and the right selector is the target snapshot. Merge commits default to their first parent, with an explicit parent selector for other parent comparisons. Commit-to-commit Diff never mutates the worktree.

Each Diff has file-level status and, when text is available, line hunks. The scene layer adds structural and property entries. Binary files remain file-level changes with an explicit binary label rather than invented text content.

### Scene Diff

Scene entries use a normalized relative `NodePath` as their primary key. Each entry contains:

- status: `ADDED`, `DELETED`, `MODIFIED`, `MOVED`, `TYPE_CHANGED`, or `CONFLICT`;
- node type and parent path where available;
- changed property names and old/new values where safe to decode;
- before and after snapshot references;
- a parse/load diagnostic when the scene cannot be safely represented.

The semantic comparison covers node structure, parent changes, node type, transform, visibility, rendering and physics properties, attached scripts, groups, metadata, signal connections, external resource references, and embedded subresources where their serialized representation is available. Generated serialization noise such as `load_steps` is excluded from the semantic list but remains visible in the raw text Diff.

The visual status colors are green for added, red for deleted, and yellow for modified. Moved, type-changed, and conflict entries also carry text labels and icons; color is never the only status signal.

For a normal Diff or merge result, deleted nodes are instantiated from the comparison snapshot as read-only red ghost geometry. For merge review, the before snapshot uses the old layer and the after snapshot uses the new layer, both with independently controlled opacity. Temporary review nodes have no scene owner, are process-disabled, have collisions disabled, and can never be serialized into the edited scene.

Scene coloring and overlay generation happen only for the current edited scene and only after the user enables the explicit scene-color toggle. Refresh is explicit or debounced from an editor scene change; there is no per-frame Git scan. Cache keys include the compared object IDs, scene path, worktree signature, and review mode. Disabling the toggle clears overlays, restores tree colors, and releases snapshot resources.

Built-in SceneTree coloring is implemented by a Godot 4.7 adapter. The adapter detects the supported editor-tree entry and applies status foreground/background colors without changing scene data. If the editor surface is unavailable, the bottom panel shows a hierarchical Diff Tree with the same paths, colors, and selection behavior. The rest of the scene visualization does not depend on the adapter.

### Conflict resolution

Text conflicts show stage 1 Base, stage 2 Ours, stage 3 Theirs, and the current worktree result. The user can take Ours, take Theirs, edit the result, write it to the worktree, and Stage it. A file is not considered resolved until the index has a normal stage entry.

For `.tscn` conflicts, the resolver builds three serialized scene models keyed by node path and property. If one side equals Base, the other side is selected automatically. When both sides diverge, the panel exposes a node/property choice between current and target content and previews the proposed result. The resolver writes a deterministic scene text result and stages it. Unsupported syntax, ambiguous node identity, or resource serialization failure falls back to whole-file three-way choice and explains the reason.

### Collaboration conveniences

The first implementation also includes Refresh, explicit Fetch, ahead/behind and recent-commit summaries, open/reveal/copy-path actions for changed files, resolved-file Stage actions, merge-message generation, and snapshot-cache cleanup. It does not add automatic stash, automatic commit, automatic push, background scanning, or a remote collaboration service.

## Architecture

### C++ Git backend

`GitPlugin` remains the registered `EditorVCSInterface` and continues to own libgit2 objects, credentials, references, index state, and error conversion. New script-facing methods are bound separately from the existing underscore-prefixed VCS endpoints so the Godot addon has a stable explicit API. All new operations return dictionaries with an `ok` boolean, a stable `code`, a user-facing `message`, and operation-specific `data`; raw libgit2 pointers never cross the extension boundary.

The backend API consists of these logical operations:

- repository state and refs, including current branch, detached state, dirty paths, merge state, and commit metadata;
- merge analysis and merge execution for a selected ref;
- tree Diff between arbitrary commit/ref trees and path-filtered file Diff;
- file/blob contents at an arbitrary ref and conflict stage 1/2/3;
- conflict status, resolved-result write, and explicit stage/unstage actions;
- existing VCS operations routed through shared helpers where behavior is equivalent.

The existing `_get_diff` override remains compatible with the Godot VCS interface. Arbitrary commit-to-commit Diff uses libgit2 tree-to-tree comparison, while existing commit-vs-parent Diff becomes a convenience call into the same helper. The existing pull path is refactored around the shared merge implementation without changing its public VCS behavior.

### Godot 4.7 addon

The addon contains a `plugin.cfg`, an `EditorPlugin` entry point, a bottom-panel controller, a backend adapter, a scene Diff model, a snapshot loader, a conflict resolver, and a scene overlay renderer. The panel owns UI state only; the backend adapter translates structured C++ results into typed GDScript models; the scene layer never calls libgit2 directly.

Snapshot files are stored below a plugin-owned `user://` cache path and loaded only for preview. They are keyed by object ID and path, cleaned after use, and invalidated on backend errors or changed worktree signatures. External resources continue to resolve against the project where possible; missing dependencies produce a non-destructive raw/structural Diff fallback.

## Error and Safety Behavior

Errors are displayed in the panel with an operation, path/ref, stable code, and recovery action. The panel distinguishes dirty worktree, missing ref, detached HEAD, repository unavailable, unfinished Git operation, authentication/network failure, binary content, scene parse failure, missing resource, stale snapshot, and unsupported merge syntax. A failed visualization never edits Git state. A failed merge never triggers an automatic cleanup that could discard user files.

The panel disables actions while a backend operation is active, refreshes state after every Git operation, and invalidates scene overlays whenever the compared data changes. Closing or disabling the addon clears only plugin-owned temporary objects and cache entries.

## Verification Strategy

1. C++/libgit2 fixture repositories exercise clean status, arbitrary tree Diff, fast-forward merge, clean merge, conflict stages, detached/missing refs, and dirty-worktree rejection.
2. Godot 4.7 headless tests exercise `.tscn` parsing, NodePath matching, added/deleted/modified/moved/type-changed classification, three-way property decisions, unsupported-syntax fallback, and snapshot cache invalidation.
3. Editor checks use gdmcp to confirm the addon loads, the bottom panel appears, branch/ref choices update, preflight blocks dirty merge, conflict entries show stage data, and the scene tree adapter or Diff Tree exposes the expected statuses.
4. Visual checks use gdmcp/editor screenshots with coloring off and on, a deleted ghost, a modified node overlay, and before/after merge review. The checks assert both non-blank rendering and the relevant node/status state.
5. Final static checks include the native build, exact script validation, `git diff --check`, and a worktree review that excludes generated snapshot/cache files.

## Acceptance Criteria

- A user can select a target ref in the bottom panel and merge it into the current checkout branch with one action when preflight is clean.
- A dirty worktree is blocked without stash or file mutation.
- The panel can compare arbitrary commits/refs and show file, text, and supported scene Diff without changing the worktree.
- A user can inspect and resolve text conflicts through Base/Ours/Theirs and stage the result.
- A user can inspect `.tscn` conflicts by node/property when safely parseable, with a clear whole-file fallback otherwise.
- When scene coloring is enabled, added/modified/deleted statuses appear in the tree or fallback Diff Tree and in the scene viewport using the agreed colors.
- Deleted content is visible as a read-only ghost, and merge review can show before/after semi-transparent layers.
- Turning scene coloring off removes temporary review objects and avoids further scene scanning.
- The feature reports actionable errors and never auto-stashes, auto-commits, or auto-pushes.
