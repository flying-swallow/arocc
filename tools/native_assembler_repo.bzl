"""Expose native assembler, ELF reader, and C compiler tools as runfiles.

These tools are discovered from PATH on the native Linux x86-64 host. They
remain host tools, so this repository is intentionally local rather than a
hermetic toolchain distribution.
"""

def _stub(ctx, name, tool):
    ctx.file(name, "#!/bin/sh\necho '%s is available only on Linux x86-64' >&2\nexit 1\n" % tool, executable = True)

def _impl(ctx):
    os_name = ctx.os.name.lower()
    arch = ctx.os.arch.lower()
    if os_name.find("linux") == -1 or arch not in ["x86_64", "amd64"]:
        # Keep the repository loadable in the cross-platform CI matrix. The
        # native integration test is constrained to Linux x86-64 and exits
        # early when invoked manually on another host.
        _stub(ctx, "as", "as")
        _stub(ctx, "readelf", "readelf")
        _stub(ctx, "cc", "cc")
    else:
        assembler = ctx.which("as")
        readelf = ctx.which("readelf")
        c_compiler = ctx.which("cc")
        if not assembler:
            fail("native assembly integration requires `as` on PATH (Linux x86-64)")
        if not readelf:
            fail("native assembly integration requires `readelf` on PATH (Linux x86-64)")
        if not c_compiler:
            fail("native backend integration requires `cc` on PATH (Linux x86-64)")
        ctx.symlink(assembler, "as")
        ctx.symlink(readelf, "readelf")
        ctx.symlink(c_compiler, "cc")

    ctx.file("BUILD.bazel", """
exports_files(["as", "readelf", "cc"], visibility = ["//visibility:public"])
""")

native_assembler_repo = repository_rule(
    implementation = _impl,
    environ = ["PATH"],
    local = True,
)
