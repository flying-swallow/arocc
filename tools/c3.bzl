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
    out = ctx.actions.declare_file(ctx.label.name)
    build_dir = out.path + ".c3build"
    args = ctx.actions.args()
    args.add("compile-test" if test else "compile")
    if test:
        args.add("--suppress-run")
    args.add(_opt_flag(ctx))
    args.add_all(ctx.attr.copts)
    args.add("--build-dir", build_dir)
    args.add("--obj-out", build_dir + "/obj")
    args.add("--output-dir", out.dirname)
    args.add("-o", out.basename)
    args.add_all(srcs)
    ctx.actions.run(
        executable = ctx.executable._c3c,
        arguments = [args],
        inputs = depset(transitive = [srcs, depset(ctx.files._std)]),
        outputs = [out],
        mnemonic = "C3Compile",
        progress_message = "Compiling C3 %{label}",
        env = {"HOME": "/tmp"},
    )
    runfiles = ctx.runfiles(files = data.to_list())
    return [DefaultInfo(executable = out, runfiles = runfiles), RunEnvironmentInfo(environment = ctx.attr.env)]

_exe_attrs = {
    "srcs": attr.label_list(allow_files = [".c3", ".c3i"]),
    "deps": attr.label_list(providers = [C3Info]),
    "data": attr.label_list(allow_files = True),
    "copts": attr.string_list(),
    "env": attr.string_dict(),
    "_c3c": _C3C,
    "_std": _STD,
}

def _bin_impl(ctx):
    return _compile(ctx, False)

def _test_impl(ctx):
    return _compile(ctx, True)

c3_binary = rule(implementation = _bin_impl, attrs = _exe_attrs, executable = True)
c3_test = rule(implementation = _test_impl, attrs = _exe_attrs, test = True)
