[![C/C++ CI](https://github.com/godotengine/godot-git-plugin/actions/workflows/build.yml/badge.svg)](https://github.com/godotengine/godot-git-plugin/actions/workflows/build.yml)

<img src="/icon.png" width="25%" />

# Godot Git Plugin

Git implementation of the Godot Engine VCS interface in Godot. We use [libgit2](https://libgit2.org) as our backend to simulate Git in code.

## Installation

1.  Grab the platform binaries here: https://github.com/godotengine/godot-git-plugin/releases
2.  Then read the installation instructions: https://github.com/godotengine/godot-git-plugin/wiki

## Git collaboration addon

The repository also includes a Godot 4.7 editor addon for branch collaboration, arbitrary ref Diff, merge review, and scene-aware change inspection. The addon is intended for Godot 4.7 and is not compatible with older editor API versions.

### Enable the addon

1.  Install the plugin binaries and copy or symlink the repository `addons` folder into the Godot project.
2.  Open the project with Godot 4.7.
3.  Open **Project > Project Settings > Plugins**, find **Godot Git Collaboration**, and set it to **Enabled**.
4.  Open the **Git Collaboration** panel from the bottom panel. Use **Refresh** after changing branches or refs outside the panel.

The panel shows the current checkout branch, repository state, target ref, changed files, and conflicts. **Fetch** is explicit and uses the configured Git backend; the addon does not perform hidden network operations.

### Diff and merge

Choose a target from the ref selector and use **Diff** to compare the current checkout with any available local branch, remote-tracking branch, tag, or commit. The Diff view can also be used for arbitrary ref/commit A-to-B comparisons when both objects are present in the repository. It reports file status and text hunks when content is text; binary files remain file-level changes.

Use **Merge** to merge the selected target ref into the current checkout branch. Before merging, the addon requires a named current branch, an existing target ref, an idle repository state, and a clean index and worktree. A dirty worktree disables or rejects the merge without stashing, committing, pushing, or modifying local files automatically. After a clean non-fast-forward merge, creating the merge commit remains an explicit user action.

### Conflict resolution

When Git reports a conflict, the conflict view exposes the three versions of each file:

- **Base**: the common ancestor.
- **Ours**: the current checkout branch.
- **Theirs**: the selected merge target.

For text conflicts, choose Base, Ours, or Theirs, edit the result when needed, write it to the worktree, and explicitly stage the resolved file. For `.tscn` conflicts, the addon compares nodes and properties when the scene can be parsed safely; otherwise it falls back to a whole-file three-way review and reports the reason. A conflict is not considered resolved until its normal index entry has been staged.

### Scene Diff and merge review

Scene coloring is disabled by default because scene scanning and temporary review objects can be expensive. Enable **Color scene** manually in the collaboration panel when reviewing the currently edited scene, then refresh the Diff to apply the visualization. The same status is shown in the scene tree or the addon Diff Tree fallback and as a transparent overlay on node surfaces:

- Green: added nodes.
- Red: deleted nodes, shown as read-only ghost geometry when a snapshot is available.
- Yellow: modified nodes.

Color is supplementary to the status text and path. In merge review, the before snapshot and after snapshot are displayed as independently adjustable semi-transparent layers so the original and merged result can be inspected together. Turning scene coloring off removes temporary overlays and stops further scene scanning; review objects are editor-only and are not serialized into the scene.

### Rebuilding the native extension

Changes to the C++ GDExtension backend or its bound API require rebuilding the native `godot-git-plugin` library and replacing the platform binary used by `addons/godot-git-plugin/git_plugin.gdextension`.

Changes limited to the Godot addon scripts do not require a native rebuild. The bundled `libgit2` normally does not need to be rebuilt when only the plugin C++ code or addon changes and the libgit2 version, ABI, and build configuration remain unchanged. Rebuild libgit2 and its dependent libraries when changing libgit2 source, version, ABI, or dependency/build settings.

## Build

This section onwards is only meant to be used if you intend to compile the plugin from source.

### Required tools

- Full copy of the source code. Remember to use `git clone --recursive`, or initialize submodules with `git submodule update --init`.
- [SCons](https://scons.org/pages/download.html) (v3.1.2+), CMake, and Perl.
- C++17 and C90 compilers detectable by SCons and present in `PATH`.

### Release build

```
scons platform=<platform> target=editor
```

> You may get the GDExtension dump yourself from Godot using the instructions in the next section, or use the ones provided in `godot-cpp`.

For more build options, run `scons platform=<platform> -h`

## Dev builds

When new features are being worked on for the Godot VCS Integration, the build process sometimes requires developers to make changes in the GDExtension API along with this plugin. This means we need to manually generate the GDExtension API from the custom Godot builds and use it to compile godot-cpp, and then finally link the resulting godot-cpp binary into this plugin.

If you need to use a custom GDExtension API:

1. Dump the new bindings from the custom Godot build.

```shell
./path/to/godot/bin/godot.<platform>.editor.<arch> --headless --dump-gdextension-interface --dump-extension-api
```

2. Build the plugin along with the godot-cpp library.

```
scons platform=<platform> target=editor generate_bindings=yes dev_build=yes
```

> You only need to build godot-cpp once every change in the GDExtension API, hence, `generate_bindings=yes` should only be passed in during the first time after generating a new GDExtension API dump.

3. To test the plugin, set up a testing project with Godot, and copy or symlink the `addons` folder.

To view more options available while recompiling godot-git-plugin, run `scons platform=<platform> -h`.

---

## License

This plugin is under the MIT License. Third-party notices are present in [THIRDPARTY.md](THIRDPARTY.md).

OpenSSL License Attributions - This product includes software developed by the OpenSSL Project for use in the OpenSSL Toolkit. (http://www.openssl.org/). This product includes cryptographic software written by Eric Young (eay@cryptsoft.com)
