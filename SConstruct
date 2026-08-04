#!/usr/bin/env python

import os

EnsureSConsVersion(3, 1, 2)
EnsurePythonVersion(3, 6)

opts = Variables([], ARGUMENTS)

env = Environment(ENV=os.environ)

# Define our options
opts.Add(PathVariable("target_path",
         "The path where the lib is installed.", "addons/godot-git-plugin/"))
opts.Add(PathVariable("target_name", "The library name.",
         "libgit_plugin", PathVariable.PathAccept))

# Updates the environment with the option variables.
opts.Update(env)

if ARGUMENTS.get("custom_api_file", "") != "":
    ARGUMENTS["custom_api_file"] = "../" + ARGUMENTS["custom_api_file"]

ARGUMENTS["target"] = "editor"
if ARGUMENTS.get("platform", "") == "linux":
    # A private static libstdc++ exports process-wide locale symbols that can
    # corrupt C++ Vulkan layers loaded later, such as LSFG.
    ARGUMENTS.setdefault("use_static_cpp", "no")
env = SConscript("godot-cpp/SConstruct").Clone()
env.__class__.msvc = env.get("is_msvc", False)

# Keep symbols from godot-cpp and bundled third-party archives private. The
# GDExtension entry point remains exported through GDE_EXPORT.
if env["platform"] == "linux":
    env.AppendUnique(LINKFLAGS=["-Wl,--exclude-libs,ALL"])

# Force linking with LTO on windows MSVC, silence the linker complaining that libgit uses LTO but we are not linking with it.
if env["platform"] == "windows" and env.get("is_msvc", False):
    env.AppendUnique(LINKFLAGS=["/LTCG"])

# OpenSSL Builder
env.Tool("openssl", toolpath=["tools"])

# SSH2 Builder
env.Tool("cmake", toolpath=["tools"])
env.Tool("ssh2", toolpath=["tools"])
env.Tool("git2", toolpath=["tools"])

opts.Update(env)

ssl = env.OpenSSL()
ssh2 = env.BuildSSH2(ssl)
ssl += ssh2
git2 = env.BuildGIT2(ssl)

Export("ssl")
Export("env")

SConscript("godot-git-plugin/SCsub")

# Generates help for the -h scons option.
Help(opts.GenerateHelpText(env))
