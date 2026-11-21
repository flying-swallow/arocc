"""Minimal C3 rules.

c3c compiles a whole program from source at once, so a c3_library only
collects sources; c3_binary / c3_test compile everything in one action.
Every source is listed explicitly (no globs inside c3c itself).
"""

C3Info = provider(fields = {"srcs": "depset of .c3 sources", "data": "depset of runtime files"})

_C3C = attr.label(default = "@c3c//:c3c", allow_single_file = True, executable = True, cfg = "exec")
_STD = attr.label(default = "@c3c//:stdlib", cfg = "exec")

def _collect(ctx):
    srcs = depset(ctx.files.srcs, transitive = [d[C3Info].srcs for d in ctx.attr.deps])
    data = depset(ctx.files.data, transitive = [d[C3Info].data for d in ctx.attr.deps])
    return srcs, data

def _lib_impl(ctx):
    srcs, data = _collect(ctx)
    return [C3Info(srcs = srcs, data = data), DefaultInfo(files = srcs)]

c3_library = rule(
    implementation = _lib_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".c3", ".c3i"]),
        "deps": attr.label_list(providers = [C3Info]),
        "data": attr.label_list(allow_files = True),
    },
)

def _opt_flag(ctx):
    mode = ctx.var.get("COMPILATION_MODE", "fastbuild")
    return "-O2" if mode == "opt" else "-O0"

def _compile(ctx, test):
    srcs, data = _collect(ctx)
    native_libs = [f for dep in ctx.attr.native_libs for f in dep.files.to_list()]
    native_objects = []
    native_cc_tools = [ctx.attr.native_cc[DefaultInfo].files_to_run] if ctx.executable.native_cc else []
    if ctx.files.native_srcs:
        if not ctx.executable.native_cc:
            fail("%s has native_srcs but no native_cc compiler was declared" % ctx.label)
        for index, source in enumerate(ctx.files.native_srcs):
            obj = ctx.actions.declare_file("%s_native_%d.o" % (ctx.label.name, index))
            cc_args = ctx.actions.args()
            cc_args.add_all(ctx.attr.native_copts)
            cc_args.add_all(["-c", source.path, "-o", obj.path])
            ctx.actions.run(
                executable = ctx.executable.native_cc,
                arguments = [cc_args],
                inputs = [source],
                outputs = [obj],
                tools = native_cc_tools,
                mnemonic = "C3NativeCompile",
                progress_message = "Compiling native sources for %{label}",
                env = ctx.attr.native_cc_env,
                use_default_shell_env = True,
            )
            native_objects.append(obj)
    native_libs += native_objects
    # The repository rule provides a host-local c3c, so the output platform is
    # the compiler host platform as well.
    windows = ctx.configuration.host_path_separator == ";"
    # On POSIX hosts a test compiles to `<name>.c3test` and `<name>` is a
    # launcher that maps Bazel's test settings onto the C3 test runner.
    launch_tests = test and not windows
    out_name = ctx.label.name + (".c3test" if launch_tests else (".exe" if windows else ""))
    out = ctx.actions.declare_file(out_name)
    # c3c writes intermediate modules and objects while compiling. Keep all of
    # them inside a declared tree artifact so sandboxed and remote actions can
    # write them, and use that same portable location for compiler scratch.
    build_tree = ctx.actions.declare_directory(ctx.label.name + ".c3build")
    build_dir = build_tree.path
    args = ctx.actions.args()
    args.add("compile-test" if test else "compile")
    if test:
        args.add("--suppress-run")
    if ctx.attr.no_entry:
        args.add("--no-entry")
    args.add(_opt_flag(ctx))
    args.add_all(ctx.attr.copts)
    # Optional native object/archive inputs are passed to c3c as raw linker
    # arguments. For Tracy, provide a compatible client library here and set
    # copts to include "-D", "TRACY" (optionally also "-D",
    # "TRACY_ALLOCATION" and/or "-D", "TRACY_CALLSTACK"). Attach the
    # library and feature flags to the final binary or test that enables
    # Tracy; c3_library deps collect sources and do not forward native libs.
    for library in native_libs:
        # -z passes a raw linker argument; unlike C3's -l flag it accepts an
        # object or archive path directly.
        args.add("-z")
        args.add(library.path)
    args.add_all(["--build-dir", build_dir])
    args.add_all(["--obj-out", build_dir + "/obj"])
    args.add("--output-dir", out.dirname)
    args.add("-o", out.basename)
    if ctx.executable.native_cc:
        # Use the same declared driver for the final link. AFL's compiler
        # driver contributes its runtime when the native harness is linked.
        args.add("--cc", ctx.executable.native_cc.path)
    args.add_all(srcs)
    ctx.actions.run(
        executable = ctx.executable._c3c,
        arguments = [args],
        inputs = depset(transitive = [srcs, depset(ctx.files._std), depset(ctx.files._c3c), depset(native_libs)], direct = [ctx.executable.native_cc] if ctx.executable.native_cc else []),
        outputs = [out, build_tree],
        mnemonic = "C3Compile",
        progress_message = "Compiling C3 %{label}",
        tools = native_cc_tools,
        env = {"HOME": build_dir, "TMPDIR": build_dir, "TMP": build_dir, "TEMP": build_dir},
        use_default_shell_env = bool(ctx.executable.native_cc),
    )
    executable = out
    extra_runfiles = []
    if launch_tests:
        executable = ctx.actions.declare_file(ctx.label.name)
        ctx.actions.expand_template(
            template = ctx.file._test_launcher,
            output = executable,
            substitutions = {"%RUNNER%": out.basename},
            is_executable = True,
        )
        extra_runfiles.append(out)
    runfiles = ctx.runfiles(files = extra_runfiles, transitive_files = data, collect_data = True)
    return [DefaultInfo(executable = executable, runfiles = runfiles), RunEnvironmentInfo(environment = ctx.attr.env)]

_exe_attrs = {
    "srcs": attr.label_list(allow_files = [".c3", ".c3i"]),
    "deps": attr.label_list(providers = [C3Info]),
    "data": attr.label_list(allow_files = True),
    "native_libs": attr.label_list(
        allow_files = True,
        doc = "Native object or archive files linked into this executable or test. These are passed to c3c as raw -z linker arguments. Attach native clients such as Tracy here on the final target that enables them; c3_library deps do not propagate native libraries.",
    ),
    "native_srcs": attr.label_list(
        allow_files = [".c"],
        doc = "C source files compiled by the declared native_cc executable and linked into this C3 target.",
    ),
    "native_cc": attr.label(
        default = None,
        executable = True,
        cfg = "exec",
        allow_files = True,
        doc = "Optional declared native C compiler executable, used only when native_srcs is nonempty.",
    ),
    "native_copts": attr.string_list(
        doc = "Options passed to native_cc when compiling native_srcs.",
    ),
    "native_cc_env": attr.string_dict(
        doc = "Environment for the optional native C compiler action; the default shell environment is also available.",
    ),
    "no_entry": attr.bool(
        default = False,
        doc = "Pass --no-entry to c3c when a native object supplies the process entry point.",
    ),
    "copts": attr.string_list(
        doc = "Additional c3c compile options. Feature defines use separate list entries, for example [\"-D\", \"TRACY\", \"-D\", \"TRACY_ALLOCATION\"].",
    ),
    "env": attr.string_dict(),
    "_test_launcher": attr.label(default = "//tools:c3_test_launcher.sh.tpl", allow_single_file = True),
    "_c3c": _C3C,
    "_std": _STD,
}

def _bin_impl(ctx):
    return _compile(ctx, False)

def _test_impl(ctx):
    return _compile(ctx, True)

c3_binary = rule(implementation = _bin_impl, attrs = _exe_attrs, executable = True)
c3_test = rule(implementation = _test_impl, attrs = _exe_attrs, test = True)

# A test whose executable is an ordinary C3 program (`fn int main`), run directly
# with no shell launcher: its exit status is the test result. `args`, `env`,
# `data`, `size` and `shard_count` work as for any Bazel test; a sharded program
# reads TEST_TOTAL_SHARDS / TEST_SHARD_INDEX and touches TEST_SHARD_STATUS_FILE.
c3_main_test = rule(implementation = _bin_impl, attrs = _exe_attrs, test = True)

def _apply_path_prefix(path, prefixes):
    # Prefer the most specific mapping when prefixes overlap.
    for key in sorted(prefixes.keys(), key = lambda value: len(value), reverse = True):
        prefix = key.rstrip("/")
        if path == prefix:
            return prefixes[key]
        if path.startswith(prefix + "/"):
            return prefixes[key].rstrip("/") + path[len(prefix):]
    return path

def _distribution_source_path(file, prefixes):
    path = _apply_path_prefix(file.short_path, prefixes)
    if path != file.short_path:
        return path

    # These outputs are generated under Bazel target names, but their stable
    # source-distribution locations follow the module names they declare.
    owner_name = file.owner.name if file.owner else ""
    if owner_name == "builtin_defs" and file.basename.endswith(".c3"):
        return "src/frontend/c/builtin_defs/" + file.basename
    if owner_name == "system_defaults_module" and file.basename == "system_defaults_module.c3":
        return "src/system_defaults.c3"
    return file.short_path

def _distribution_data_path(file, prefixes):
    return _apply_path_prefix(file.short_path, prefixes)

def _normalize_archive_path(path, file):
    # External-repository short paths start with ../<repo>. Keep them inside
    # the archive while preserving the repository-relative remainder.
    parts = path.split("/")
    if parts[0] == "..":
        if len(parts) < 3 or not parts[1]:
            fail("c3_source_archive: invalid source-relative path %s for %s" % (path, file.path))
        path = "external/" + "/".join(parts[1:])
        parts = path.split("/")

    normalized = []
    for part in parts:
        if part == "" or part == ".":
            continue
        if part == "..":
            fail("c3_source_archive: archive path escapes its root: %s for %s" % (path, file.path))
        normalized.append(part)
    if not normalized or path.startswith("/"):
        fail("c3_source_archive: expected a relative archive path, got %s for %s" % (path, file.path))
    return "/".join(normalized)

def _add_archive_entry(entries, file, path):
    path = _normalize_archive_path(path, file)
    if path in entries and entries[path].path != file.path:
        previous = entries[path]
        fail("c3_source_archive: %s and %s both map to %s" % (previous.path, file.path, path))
    entries[path] = file

def _c3_source_archive_impl(ctx):
    transitive_srcs, transitive_data = _collect(ctx)
    entries = {}

    for file in transitive_srcs.to_list():
        _add_archive_entry(entries, file, _distribution_source_path(file, ctx.attr.src_path_prefixes))
    for file in transitive_data.to_list():
        _add_archive_entry(entries, file, _distribution_data_path(file, ctx.attr.data_path_prefixes))

    archive = ctx.actions.declare_file(ctx.label.name + ".zip")
    args = ctx.actions.args()
    args.add("c")
    args.add(archive.path)
    input_files = []
    for path in sorted(entries.keys()):
        file = entries[path]
        # zipper takes ZIP_PATH=FILE and splits on the first '='.
        if "=" in path:
            fail("c3_source_archive: archive path may not contain '=': %s" % path)
        args.add("%s=%s" % (path, file.path))
        input_files.append(file)
    ctx.actions.run(
        executable = ctx.executable._zipper,
        arguments = [args],
        inputs = depset(input_files),
        tools = [ctx.executable._zipper],
        outputs = [archive],
        mnemonic = "C3SourceArchive",
        progress_message = "Packaging C3 source distribution %{label}",
    )
    return [DefaultInfo(files = depset([archive]))]

c3_source_archive = rule(
    implementation = _c3_source_archive_impl,
    attrs = {
        "deps": attr.label_list(
            providers = [C3Info],
            doc = "C3 libraries whose transitive sources and declared data are included.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Additional runtime resources to include with their source-relative paths.",
        ),
        "srcs": attr.label_list(
            allow_files = True,
            doc = "Additional files such as a standalone BUILD file or rule sources.",
        ),
        "src_path_prefixes": attr.string_dict(
            doc = "Optional archive path-prefix rewrites for C3 sources, keyed by File.short_path.",
        ),
        "data_path_prefixes": attr.string_dict(
            doc = "Optional archive path-prefix rewrites for runtime data, keyed by File.short_path.",
        ),
        "_zipper": attr.label(
            default = Label("@bazel_tools//tools/zip:zipper"),
            allow_files = True,
            executable = True,
            cfg = "exec",
        ),
    },
    doc = "Creates a relocatable zip archive from C3Info sources, transitive runtime data, and extra files.",
)
