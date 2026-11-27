"""Locates a host c3c install (C3C env var, else PATH) and exposes it as @c3c.

This is a local, non-hermetic toolchain: the action cache keys on the
compiler's files, but the install itself comes from the host.
"""

# Candidate compiler pin. Keep the revision check: a version label alone is not reproducible.
CANDIDATE_VERSION = "0.8.6"
CANDIDATE_REVISION = "61d33ae1dce61f80dd81660db2f9910208c74284"

def _candidate_names(rctx):
    if rctx.os.name.lower().find("windows") != -1:
        return ["c3c.exe", "c3c"]
    return ["c3c"]

def _compiler_from_override(rctx, override):
    path = rctx.path(override)
    if path.exists and path.is_dir:
        for name in _candidate_names(rctx):
            candidate = path.get_child(name)
            if candidate.exists:
                return candidate
        # Support the common archive layout with the executable under bin/.
        for name in _candidate_names(rctx):
            candidate = path.get_child("bin").get_child(name)
            if candidate.exists:
                return candidate
        return None
    return path

def _compiler_from_path(rctx):
    for name in _candidate_names(rctx):
        path = rctx.which(name)
        if path:
            return path
    return None

def _impl(rctx):
    override = rctx.os.environ.get("C3C", "")
    compiler = _compiler_from_override(rctx, override) if override else _compiler_from_path(rctx)
    if not compiler or not compiler.exists:
        fail("c3c not found. Set C3C to the compiler path or install directory (with lib/std), or put c3c on PATH. Candidate version/revision: %s / %s" % (CANDIDATE_VERSION, CANDIDATE_REVISION))

    # Official archives use either <root>/c3c or <root>/bin/c3c, with
    # <root>/lib/std in both cases. Keep the compiler and lib tree separately
    # linked so the stdlib filegroup includes every distribution input.
    root = compiler.dirname.dirname if compiler.dirname.basename == "bin" else compiler.dirname
    lib = root.get_child("lib")
    if not lib.exists or not lib.get_child("std").exists:
        fail("c3c at %s has no sibling lib/std directory; set C3C to the compiler distribution executable or its install directory" % compiler)

    res = rctx.execute([compiler, "--version"])
    if res.return_code != 0:
        fail("`%s --version` failed: %s" % (compiler, res.stderr))
    version_matches = ("Version:       " + CANDIDATE_VERSION) in res.stdout or ("Version: " + CANDIDATE_VERSION) in res.stdout
    revision_matches = ("Git Hash:                  " + CANDIDATE_REVISION) in res.stdout or ("Git Hash: " + CANDIDATE_REVISION) in res.stdout
    if not version_matches or not revision_matches:
        print("WARNING: c3c at %s does not match candidate version %s and exact Git revision %s. Continuing with this compiler.\n%s" % (compiler, CANDIDATE_VERSION, CANDIDATE_REVISION, res.stdout))

    # Bazel's Windows launcher relies on the .exe suffix when a target is
    # consumed through an executable attribute. Keep the stable basename on
    # Unix, where executable suffixes are not used.
    executable_name = "compiler.exe" if rctx.os.name.lower().find("windows") != -1 else "compiler"
    rctx.symlink(compiler, executable_name)
    rctx.symlink(lib, "lib")
    rctx.file("BUILD.bazel", """
filegroup(name = "c3c", srcs = ["%s"], visibility = ["//visibility:public"])
filegroup(name = "stdlib", srcs = glob(["lib/**"], allow_empty = False), visibility = ["//visibility:public"])
""" % executable_name)

c3c_repo = repository_rule(
    implementation = _impl,
    environ = ["C3C", "PATH"],
    local = True,
)
