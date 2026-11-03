"""Locates a host c3c install (C3C env var, else PATH) and exposes it as @c3c.

This is a local, non-hermetic toolchain: the action cache keys on the
compiler's files, but the install itself comes from the host.
"""

SUPPORTED = "0.8.5"

def _impl(rctx):
    c3c = rctx.os.environ.get("C3C", "")
    if c3c:
        path = rctx.path(c3c)
    else:
        path = rctx.which("c3c")
    if not path or not path.exists:
        fail("c3c not found. Set C3C=/path/to/c3c (the c3c install directory must also contain lib/std) or put c3c on PATH. Supported version: " + SUPPORTED)
    res = rctx.execute([path, "--version"])
    if res.return_code != 0:
        fail("`%s --version` failed: %s" % (path, res.stderr))
    if ("Version:       " + SUPPORTED) not in res.stdout and ("Version: " + SUPPORTED) not in res.stdout:
        print("WARNING: c3c at %s is not the supported version %s:\n%s" % (path, SUPPORTED, res.stdout))
    rctx.symlink(path.dirname, "install")
    rctx.file("BUILD.bazel", """
filegroup(name = "c3c", srcs = ["install/c3c"], visibility = ["//visibility:public"])
filegroup(name = "stdlib", srcs = glob(["install/lib/**"]), visibility = ["//visibility:public"])
""")

c3c_repo = repository_rule(
    implementation = _impl,
    environ = ["C3C", "PATH"],
    local = True,
)
