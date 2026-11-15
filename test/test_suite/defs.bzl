"""Per-area test targets for test/test_suite, all running one runner binary."""

def _suite_test_impl(ctx):
    runner = ctx.executable.runner
    out = ctx.actions.declare_file(ctx.label.name + (".exe" if runner.extension == "exe" else ""))
    ctx.actions.symlink(output = out, target_file = runner, is_executable = True)
    runfiles = ctx.runfiles(files = ctx.files.data)
    runfiles = runfiles.merge(ctx.attr.runner[DefaultInfo].default_runfiles)
    for d in ctx.attr.data:
        runfiles = runfiles.merge(d[DefaultInfo].default_runfiles)
    return [
        DefaultInfo(executable = out, runfiles = runfiles),
        RunEnvironmentInfo(environment = ctx.attr.env),
    ]

_suite_test = rule(
    implementation = _suite_test_impl,
    test = True,
    attrs = {
        "runner": attr.label(
            default = "//test/src/test_suite:test_suite_runner",
            executable = True,
            cfg = "target",
        ),
        "data": attr.label_list(allow_files = True),
        "env": attr.string_dict(),
    },
)

_NATIVE_TOOLS = [
    "@native_assembler_tools//:cc",
    "@native_assembler_tools//:as",
]

def test_suite_area(area, native = False, name = None, env = {}, **kwargs):
    """`test_suite_<area>`: runs test_suite_runner on test/test_suite/<area>.

    Args:
      area: the subdirectory of test/test_suite.
      native: the area has `run` cases (links with the declared cc).
      name: target name; defaults to test_suite_<area>.
      env: extra test environment (ARO_C3_OPT, ARO_C3_FLAGS).
      **kwargs: forwarded to the test rule (tags, size, ...).
    """
    args = [
        "$(location //:aro_c3)",
        "test/test_suite/" + area,
        "--no-terminal",
    ]
    data = ["//:aro_c3", ":" + area, ":_support"]
    if native:
        args += ["--cc", "$(location @native_assembler_tools//:cc)"]
        data += _NATIVE_TOOLS
    _suite_test(
        name = name or "test_suite_" + area,
        args = args,
        data = data,
        env = env,
        **kwargs
    )
