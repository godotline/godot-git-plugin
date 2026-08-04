#include "git_plugin.h"

#include <algorithm>
#include <cstring>

#include "godot_cpp/classes/file_access.hpp"
#include "godot_cpp/variant/utility_functions.hpp"
#include "git2/blob.h"
#include "git2/branch.h"
#include "git2/checkout.h"
#include "git2/commit.h"
#include "git2/diff.h"
#include "git2/index.h"
#include "git2/merge.h"
#include "git2/object.h"
#include "git2/repository.h"
#include "git2/refs.h"
#include "git2/status.h"
#include "git2/tag.h"
#include "git2/tree.h"

namespace {

using namespace godot;

Dictionary ok_result(const Variant &data) {
	Dictionary result;
	result["ok"] = true;
	result["code"] = "ok";
	result["message"] = "";
	result["data"] = data;
	return result;
}

Dictionary error_result(const String &code, const String &message) {
	Dictionary result;
	result["ok"] = false;
	result["code"] = code;
	result["message"] = message;
	result["data"] = Dictionary();
	return result;
}

bool is_path_safe(const String &path) {
	if (path.is_empty() || path.begins_with("/") || path.begins_with("\\") || path.contains("://")) {
		return false;
	}
	PackedStringArray parts = path.replace("\\", "/").split("/", false);
	for (const String &part : parts) {
		if (part.is_empty() || part == "." || part == "..") {
			return false;
		}
	}
	return true;
}

String worktree_path(GitPlugin *plugin) {
	if (plugin->repo) {
		const char *workdir = git_repository_workdir(plugin->repo.get());
		if (workdir) {
			return String::utf8(workdir);
		}
	}
	return plugin->repo_project_path;
}

String state_name(int state) {
	switch (state) {
		case GIT_REPOSITORY_STATE_MERGE:
			return "merge";
		case GIT_REPOSITORY_STATE_REVERT:
			return "revert";
		case GIT_REPOSITORY_STATE_REVERT_SEQUENCE:
			return "revert_sequence";
		case GIT_REPOSITORY_STATE_CHERRYPICK:
			return "cherrypick";
		case GIT_REPOSITORY_STATE_CHERRYPICK_SEQUENCE:
			return "cherrypick_sequence";
		case GIT_REPOSITORY_STATE_BISECT:
			return "bisect";
		case GIT_REPOSITORY_STATE_REBASE:
			return "rebase";
		case GIT_REPOSITORY_STATE_REBASE_INTERACTIVE:
			return "rebase_interactive";
		case GIT_REPOSITORY_STATE_REBASE_MERGE:
			return "rebase_merge";
		default:
			return "idle";
	}
}

bool resolve_tree(GitPlugin *plugin, const String &name, git_tree_ptr &tree, String &error_message) {
	if (!plugin->repo) {
		error_message = "Repository is not initialized";
		return false;
	}
	CString c_name(name);
	git_object_ptr object;
	int error = git_revparse_single(Capture(object), plugin->repo.get(), c_name.data);
	if (error != 0) {
		error_message = "Could not resolve ref " + name;
		return false;
	}
	git_object_ptr peeled;
	error = git_object_peel(Capture(peeled), object.get(), GIT_OBJECT_TREE);
	if (error != 0) {
		error_message = "Ref does not resolve to a tree: " + name;
		return false;
	}
	error = git_tree_lookup(Capture(tree), plugin->repo.get(), git_object_id(peeled.get()));
	if (error != 0) {
		error_message = "Could not load tree for " + name;
		return false;
	}
	return true;
}

bool resolve_commit(GitPlugin *plugin, const String &name, git_commit_ptr &commit, String &error_message) {
	if (!plugin->repo) {
		error_message = "Repository is not initialized";
		return false;
	}
	CString c_name(name);
	git_object_ptr object;
	int error = git_revparse_single(Capture(object), plugin->repo.get(), c_name.data);
	if (error != 0) {
		error_message = "Could not resolve ref " + name;
		return false;
	}
	git_object_ptr peeled;
	error = git_object_peel(Capture(peeled), object.get(), GIT_OBJECT_COMMIT);
	if (error != 0) {
		error_message = "Ref does not resolve to a commit: " + name;
		return false;
	}
	error = git_commit_lookup(Capture(commit), plugin->repo.get(), git_object_id(peeled.get()));
	if (error != 0) {
		error_message = "Could not load commit for " + name;
		return false;
	}
	return true;
}

void append_ref(TypedArray<Dictionary> &refs, const String &name, const String &type, const git_oid *oid, bool is_head) {
	Dictionary ref;
	ref["name"] = name;
	ref["type"] = type;
	ref["is_head"] = is_head;
	ref["oid"] = oid ? String::utf8(git_oid_tostr_s(oid)) : String();
	refs.push_back(ref);
}

bool get_status_counts(GitPlugin *plugin, int &staged_count, int &unstaged_count, int &conflict_count) {
	staged_count = 0;
	unstaged_count = 0;
	conflict_count = 0;
	if (!plugin->repo) {
		return false;
	}
	git_status_options options = GIT_STATUS_OPTIONS_INIT;
	options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR;
	options.flags = GIT_STATUS_OPT_EXCLUDE_SUBMODULES | GIT_STATUS_OPT_INCLUDE_UNTRACKED | GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS;
	git_status_list_ptr statuses;
	if (git_status_list_new(Capture(statuses), plugin->repo.get(), &options) != 0) {
		return false;
	}
	for (size_t index = 0; index < git_status_list_entrycount(statuses.get()); ++index) {
		const git_status_entry *entry = git_status_byindex(statuses.get(), index);
		if (!entry) {
			continue;
		}
		const unsigned int index_mask = GIT_STATUS_INDEX_NEW | GIT_STATUS_INDEX_MODIFIED | GIT_STATUS_INDEX_DELETED | GIT_STATUS_INDEX_RENAMED | GIT_STATUS_INDEX_TYPECHANGE;
		const unsigned int worktree_mask = GIT_STATUS_WT_NEW | GIT_STATUS_WT_MODIFIED | GIT_STATUS_WT_DELETED | GIT_STATUS_WT_RENAMED | GIT_STATUS_WT_TYPECHANGE;
		if (entry->status & index_mask) {
			staged_count++;
		}
		if (entry->status & worktree_mask) {
			unstaged_count++;
		}
		if (entry->status & GIT_STATUS_CONFLICTED) {
			conflict_count++;
		}
	}
	return true;
}

bool merge_preflight(GitPlugin *plugin, const String &target_ref, Dictionary &result, git_commit_ptr &target_commit) {
	if (!plugin->repo) {
		result = error_result("repository_unavailable", "Repository is not initialized");
		return false;
	}
	if (git_repository_is_bare(plugin->repo.get())) {
		result = error_result("bare_repository", "A working tree is required for merge");
		return false;
	}
	String current_branch = plugin->_get_current_branch_name();
	if (current_branch.is_empty()) {
		result = error_result("detached_head", "Merge requires a named current branch");
		return false;
	}
	if (target_ref.is_empty() || target_ref == current_branch) {
		result = error_result("invalid_target", "Target ref must differ from the current branch");
		return false;
	}
	int state = git_repository_state(plugin->repo.get());
	if (state != GIT_REPOSITORY_STATE_NONE) {
		result = error_result("operation_in_progress", "Repository has an unfinished Git operation");
		return false;
	}
	int staged = 0;
	int unstaged = 0;
	int conflicts = 0;
	if (!get_status_counts(plugin, staged, unstaged, conflicts)) {
		result = error_result("status_failed", "Could not inspect the repository status");
		return false;
	}
	if (staged != 0 || unstaged != 0 || conflicts != 0) {
		result = error_result("dirty_worktree", "Commit or stage all changes before merging");
		return false;
	}
	String error_message;
	if (!resolve_commit(plugin, target_ref, target_commit, error_message)) {
		result = error_result("missing_target", error_message);
		return false;
	}
	return true;
}

} // namespace

using namespace godot;

Dictionary GitPlugin::collaboration_result(bool ok, const String &code, const String &message, const Variant &data) const {
	Dictionary result;
	result["ok"] = ok;
	result["code"] = code;
	result["message"] = message;
	result["data"] = data;
	return result;
}

Dictionary GitPlugin::collaboration_initialize(const String &project_path) {
	if (!_initialize(project_path)) {
		return collaboration_result(false, "initialize_failed", "Could not initialize the Git repository");
	}
	return collaboration_result(true, "ok", "", collaboration_get_repository_state().get("data", Dictionary()));
}

Dictionary GitPlugin::collaboration_get_repository_state() {
	if (!repo) {
		return collaboration_result(false, "repository_unavailable", "Repository is not initialized");
	}
	int staged = 0;
	int unstaged = 0;
	int conflicts = 0;
	if (!get_status_counts(this, staged, unstaged, conflicts)) {
		return collaboration_result(false, "status_failed", "Could not inspect the repository status");
	}
	Dictionary state;
	String current_branch = _get_current_branch_name();
	state["current_branch"] = current_branch;
	state["detached"] = current_branch.is_empty();
	state["staged_count"] = staged;
	state["unstaged_count"] = unstaged;
	state["conflict_count"] = conflicts;
	state["dirty"] = staged > 0 || unstaged > 0 || conflicts > 0;
	state["repository_state"] = state_name(git_repository_state(repo.get()));
	return collaboration_result(true, "ok", "", state);
}

TypedArray<Dictionary> GitPlugin::collaboration_get_refs() {
	TypedArray<Dictionary> refs;
	if (!repo) {
		return refs;
	}
	String current_branch = _get_current_branch_name();
	for (git_branch_t branch_type : { GIT_BRANCH_LOCAL, GIT_BRANCH_REMOTE }) {
		git_branch_iterator_ptr iterator;
		if (git_branch_iterator_new(Capture(iterator), repo.get(), branch_type) != 0) {
			continue;
		}
		git_reference_ptr reference;
		git_branch_t returned_type;
		while (git_branch_next(Capture(reference), &returned_type, iterator.get()) == 0) {
			const char *name = nullptr;
			if (git_branch_name(&name, reference.get()) != 0 || !name) {
				continue;
			}
			const git_oid *oid = git_reference_target(reference.get());
			append_ref(refs, String::utf8(name), branch_type == GIT_BRANCH_LOCAL ? "local" : "remote", oid, String::utf8(name) == current_branch);
		}
	}
	git_strarray tags;
	if (git_tag_list(&tags, repo.get()) == 0) {
		for (size_t index = 0; index < tags.count; ++index) {
			git_object_ptr object;
			CString tag_name(String::utf8(tags.strings[index]));
			if (git_revparse_single(Capture(object), repo.get(), tag_name.data) == 0) {
				git_object_ptr peeled;
				if (git_object_peel(Capture(peeled), object.get(), GIT_OBJECT_COMMIT) == 0) {
					append_ref(refs, String::utf8(tags.strings[index]), "tag", git_object_id(peeled.get()), false);
				}
			}
		}
		git_strarray_dispose(&tags);
	}
	return refs;
}

Dictionary GitPlugin::collaboration_diff_refs(const String &base_ref, const String &target_ref, const String &path_filter) {
	if (!repo) {
		return collaboration_result(false, "repository_unavailable", "Repository is not initialized");
	}
	String error_message;
	git_tree_ptr base_tree;
	git_tree_ptr target_tree;
	if (!resolve_tree(this, base_ref, base_tree, error_message)) {
		return collaboration_result(false, "missing_base", error_message);
	}
	if (!resolve_tree(this, target_ref, target_tree, error_message)) {
		return collaboration_result(false, "missing_target", error_message);
	}
	git_diff_options options = GIT_DIFF_OPTIONS_INIT;
	options.context_lines = 2;
	options.interhunk_lines = 0;
	options.flags = GIT_DIFF_RECURSE_UNTRACKED_DIRS | GIT_DIFF_INCLUDE_TYPECHANGE | GIT_DIFF_IGNORE_SUBMODULES;
	CString pathspec(path_filter);
	if (!path_filter.is_empty()) {
		options.pathspec.strings = &pathspec.data;
		options.pathspec.count = 1;
	}
	git_diff_ptr diff;
	int error = git_diff_tree_to_tree(Capture(diff), repo.get(), base_tree.get(), target_tree.get(), &options);
	if (error != 0) {
		return collaboration_result(false, "diff_failed", "Could not create the tree Diff");
	}
	git_diff_find_options find_options = GIT_DIFF_FIND_OPTIONS_INIT;
	find_options.flags = GIT_DIFF_FIND_RENAMES | GIT_DIFF_FIND_COPIES;
	git_diff_find_similar(diff.get(), &find_options);
	return collaboration_result(true, "ok", "", _parse_diff(diff.get()));
}

Dictionary GitPlugin::collaboration_get_blob(const String &ref_name, const String &path) {
	if (!repo) {
		return collaboration_result(false, "repository_unavailable", "Repository is not initialized");
	}
	String error_message;
	git_tree_ptr tree;
	if (!resolve_tree(this, ref_name, tree, error_message)) {
		return collaboration_result(false, "missing_ref", error_message);
	}
	CString c_path(path);
	git_tree_entry_ptr entry;
	if (git_tree_entry_bypath(Capture(entry), tree.get(), c_path.data) != 0 || !entry || git_tree_entry_type(entry.get()) != GIT_OBJECT_BLOB) {
		return collaboration_result(false, "missing_blob", "The ref does not contain a file at " + path);
	}
	git_blob_ptr blob;
	if (git_blob_lookup(Capture(blob), repo.get(), git_tree_entry_id(entry.get())) != 0) {
		return collaboration_result(false, "blob_failed", "Could not load " + path);
	}
	Dictionary data;
	data["path"] = path;
	data["binary"] = git_blob_is_binary(blob.get()) != 0;
	data["size"] = static_cast<int64_t>(git_blob_rawsize(blob.get()));
	if (!static_cast<bool>(data["binary"])) {
		const char *raw_content = static_cast<const char *>(git_blob_rawcontent(blob.get()));
		data["text"] = String::utf8(raw_content, static_cast<int>(git_blob_rawsize(blob.get())));
	}
	return collaboration_result(true, "ok", "", data);
}

Dictionary GitPlugin::collaboration_analyze_merge(const String &target_ref) {
	git_commit_ptr target_commit;
	Dictionary preflight;
	if (!merge_preflight(this, target_ref, preflight, target_commit)) {
		return preflight;
	}
	git_reference_ptr head;
	if (git_repository_head(Capture(head), repo.get()) != 0) {
		return collaboration_result(false, "head_failed", "Could not load current HEAD");
	}
	git_annotated_commit_ptr annotated;
	if (git_annotated_commit_lookup(Capture(annotated), repo.get(), git_commit_id(target_commit.get())) != 0) {
		return collaboration_result(false, "target_failed", "Could not create merge target");
	}
	const git_annotated_commit *heads[] = { annotated.get() };
	git_merge_analysis_t analysis = GIT_MERGE_ANALYSIS_NONE;
	git_merge_preference_t preference = GIT_MERGE_PREFERENCE_NONE;
	if (git_merge_analysis(&analysis, &preference, repo.get(), heads, 1) != 0) {
		return collaboration_result(false, "merge_analysis_failed", "Could not analyze the merge");
	}
	Dictionary data;
	data["target"] = target_ref;
	if (analysis & GIT_MERGE_ANALYSIS_UP_TO_DATE) {
		data["outcome"] = "up_to_date";
	} else if (analysis & GIT_MERGE_ANALYSIS_FASTFORWARD) {
		data["outcome"] = "fast_forward";
	} else if (analysis & GIT_MERGE_ANALYSIS_NORMAL) {
		data["outcome"] = "clean_merge";
	} else {
		data["outcome"] = "rejected";
	}
	data["preference"] = static_cast<int>(preference);
	return collaboration_result(true, "ok", "", data);
}

Dictionary GitPlugin::collaboration_merge_ref(const String &target_ref) {
	git_commit_ptr target_commit;
	Dictionary preflight;
	if (!merge_preflight(this, target_ref, preflight, target_commit)) {
		return preflight;
	}
	git_annotated_commit_ptr annotated;
	if (git_annotated_commit_lookup(Capture(annotated), repo.get(), git_commit_id(target_commit.get())) != 0) {
		return collaboration_result(false, "target_failed", "Could not create merge target");
	}
	const git_annotated_commit *heads[] = { annotated.get() };
	git_merge_analysis_t analysis = GIT_MERGE_ANALYSIS_NONE;
	git_merge_preference_t preference = GIT_MERGE_PREFERENCE_NONE;
	if (git_merge_analysis(&analysis, &preference, repo.get(), heads, 1) != 0) {
		return collaboration_result(false, "merge_analysis_failed", "Could not analyze the merge");
	}
	if (analysis & GIT_MERGE_ANALYSIS_UP_TO_DATE) {
		Dictionary data;
		data["outcome"] = "up_to_date";
		return collaboration_result(true, "ok", "Already up to date", data);
	}
	if (analysis & GIT_MERGE_ANALYSIS_FASTFORWARD) {
		git_object_ptr target_object;
		if (git_object_lookup(Capture(target_object), repo.get(), git_commit_id(target_commit.get()), GIT_OBJECT_COMMIT) != 0) {
			return collaboration_result(false, "target_failed", "Could not load fast-forward target");
		}
		git_checkout_options checkout_options = GIT_CHECKOUT_OPTIONS_INIT;
		checkout_options.checkout_strategy = GIT_CHECKOUT_SAFE;
		if (git_checkout_tree(repo.get(), target_object.get(), &checkout_options) != 0) {
			return collaboration_result(false, "checkout_failed", "Could not checkout the fast-forward result");
		}
		git_reference_ptr head;
		if (git_repository_head(Capture(head), repo.get()) != 0) {
			return collaboration_result(false, "head_failed", "Could not load current HEAD");
		}
		git_reference_ptr updated_head;
		if (git_reference_set_target(Capture(updated_head), head.get(), git_commit_id(target_commit.get()), "Godot Git Collaboration fast-forward") != 0) {
			return collaboration_result(false, "reference_update_failed", "Could not update the current branch");
		}
		Dictionary data;
		data["outcome"] = "fast_forward";
		return collaboration_result(true, "ok", "Fast-forward complete", data);
	}
	if (!(analysis & GIT_MERGE_ANALYSIS_NORMAL)) {
		return collaboration_result(false, "merge_rejected", "Git rejected this merge");
	}
	git_merge_options merge_options = GIT_MERGE_OPTIONS_INIT;
	merge_options.file_favor = GIT_MERGE_FILE_FAVOR_NORMAL;
	merge_options.file_flags = GIT_MERGE_FILE_STYLE_DIFF3 | GIT_MERGE_FILE_DIFF_MINIMAL;
	git_checkout_options checkout_options = GIT_CHECKOUT_OPTIONS_INIT;
	checkout_options.checkout_strategy = GIT_CHECKOUT_SAFE | GIT_CHECKOUT_ALLOW_CONFLICTS | GIT_CHECKOUT_CONFLICT_STYLE_MERGE;
	if (git_merge(repo.get(), heads, 1, &merge_options, &checkout_options) != 0) {
		return collaboration_result(false, "merge_failed", "Could not merge the selected ref");
	}
	pull_merge_oid = *git_commit_id(target_commit.get());
	has_merge = true;
	Dictionary data;
	data["outcome"] = "clean_merge";
	TypedArray<Dictionary> conflicts = collaboration_get_conflicts();
	if (!conflicts.is_empty()) {
		data["outcome"] = "conflicts";
	}
	data["conflicts"] = conflicts;
	return collaboration_result(true, "ok", conflicts.is_empty() ? "Merge complete; create a merge commit" : "Merge has conflicts", data);
}

TypedArray<Dictionary> GitPlugin::collaboration_get_conflicts() {
	TypedArray<Dictionary> conflicts;
	if (!repo) {
		return conflicts;
	}
	git_index_ptr index;
	if (git_repository_index(Capture(index), repo.get()) != 0) {
		return conflicts;
	}
	git_index_conflict_iterator *iterator = nullptr;
	if (git_index_conflict_iterator_new(&iterator, index.get()) != 0) {
		return conflicts;
	}
	const git_index_entry *ancestor = nullptr;
	const git_index_entry *ours = nullptr;
	const git_index_entry *theirs = nullptr;
	while (git_index_conflict_next(&ancestor, &ours, &theirs, iterator) == 0) {
		const git_index_entry *selected = ours ? ours : (theirs ? theirs : ancestor);
		if (!selected || !selected->path) {
			continue;
		}
		Dictionary conflict;
		conflict["path"] = String::utf8(selected->path);
		conflict["has_base"] = ancestor != nullptr;
		conflict["has_ours"] = ours != nullptr;
		conflict["has_theirs"] = theirs != nullptr;
		conflicts.push_back(conflict);
	}
	git_index_conflict_iterator_free(iterator);
	return conflicts;
}

TypedArray<Dictionary> GitPlugin::collaboration_get_worktree_files() {
	if (!repo) {
		return TypedArray<Dictionary>();
	}
	return _get_modified_files_data();
}

Dictionary GitPlugin::collaboration_get_conflict_blob(const String &path, int32_t stage) {
	if (!repo) {
		return collaboration_result(false, "repository_unavailable", "Repository is not initialized");
	}
	if (stage < 1 || stage > 3 || !is_path_safe(path)) {
		return collaboration_result(false, "invalid_conflict_stage", "Conflict stage or path is invalid");
	}
	git_index_ptr index;
	if (git_repository_index(Capture(index), repo.get()) != 0) {
		return collaboration_result(false, "index_failed", "Could not load the repository index");
	}
	const git_index_entry *ancestor = nullptr;
	const git_index_entry *ours = nullptr;
	const git_index_entry *theirs = nullptr;
	CString c_path(path);
	if (git_index_conflict_get(&ancestor, &ours, &theirs, index.get(), c_path.data) != 0) {
		return collaboration_result(false, "conflict_not_found", "No conflict exists for " + path);
	}
	const git_index_entry *entry = stage == 1 ? ancestor : (stage == 2 ? ours : theirs);
	if (!entry) {
		return collaboration_result(false, "stage_not_found", "Requested conflict stage is not present");
	}
	git_blob_ptr blob;
	if (git_blob_lookup(Capture(blob), repo.get(), &entry->id) != 0) {
		return collaboration_result(false, "blob_failed", "Could not load conflict content");
	}
	Dictionary data;
	data["path"] = path;
	data["stage"] = stage;
	data["binary"] = git_blob_is_binary(blob.get()) != 0;
	if (!static_cast<bool>(data["binary"])) {
		const char *raw_content = static_cast<const char *>(git_blob_rawcontent(blob.get()));
		data["text"] = String::utf8(raw_content, static_cast<int>(git_blob_rawsize(blob.get())));
	}
	return collaboration_result(true, "ok", "", data);
}

Dictionary GitPlugin::collaboration_write_and_stage(const String &path, const String &content) {
	if (!repo) {
		return collaboration_result(false, "repository_unavailable", "Repository is not initialized");
	}
	if (!is_path_safe(path)) {
		return collaboration_result(false, "invalid_path", "Path must remain inside the repository");
	}
	Ref<FileAccess> file = FileAccess::open(worktree_path(this).path_join(path), FileAccess::WRITE);
	if (file.is_null()) {
		return collaboration_result(false, "write_failed", "Could not write " + path);
	}
	file->store_string(content);
	file->close();
	CString c_path(path);
	git_index_ptr index;
	if (git_repository_index(Capture(index), repo.get()) != 0 || git_index_add_bypath(index.get(), c_path.data) != 0 || git_index_write(index.get()) != 0) {
		return collaboration_result(false, "stage_failed", "Could not stage " + path);
	}
	Dictionary data;
	data["path"] = path;
	data["resolved"] = true;
	return collaboration_result(true, "ok", "Resolved and staged", data);
}

Dictionary GitPlugin::collaboration_commit(const String &message) {
	if (!repo) {
		return collaboration_result(false, "repository_unavailable", "Repository is not initialized");
	}
	if (!has_merge || git_repository_state(repo.get()) != GIT_REPOSITORY_STATE_MERGE) {
		return collaboration_result(false, "merge_commit_unavailable", "There is no pending merge commit");
	}
	if (message.strip_edges().is_empty()) {
		return collaboration_result(false, "empty_commit_message", "A merge commit message is required");
	}
	int staged = 0;
	int unstaged = 0;
	int conflicts = 0;
	if (!get_status_counts(this, staged, unstaged, conflicts) || unstaged != 0 || conflicts != 0) {
		return collaboration_result(false, "dirty_worktree", "Resolve conflicts and stage all merge changes before committing");
	}
	_commit(message, false);
	if (has_merge || git_repository_state(repo.get()) != GIT_REPOSITORY_STATE_NONE) {
		return collaboration_result(false, "commit_failed", "Could not create the merge commit");
	}
	Dictionary data;
	data["outcome"] = "merge_commit";
	return collaboration_result(true, "ok", "Merge commit created", data);
}

Dictionary GitPlugin::collaboration_fetch(const String &remote) {
	if (!repo) {
		return collaboration_result(false, "repository_unavailable", "Repository is not initialized");
	}
	if (remote.strip_edges().is_empty()) {
		return collaboration_result(false, "invalid_remote", "A remote name is required");
	}
	_fetch(remote);
	Dictionary data;
	data["remote"] = remote;
	return collaboration_result(true, "ok", "Fetch requested for " + remote, data);
}
