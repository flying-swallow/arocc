"""Owner: 12.2 table-gen (skeleton by plan 12 stage 0).

`builtin_defs` runs //tools:generate_def once per .def file and outputs the
generated C3 table modules (aro::builtin_defs::<group>), which //:aro_c3_lib
lists as sources. Layout: tools/builtins_schema.md.

Invariants:
- Every .def file is a declared input of exactly the action that reads it, so
  editing one .def reruns only that group's action (and everything compiled
  from aro_c3_lib).
- The group name is the .def basename; outputs go to
  <package>/<name>/<group>.c3. The generator receives only the input path,
  output path and group, so the outputs do not depend on the execroot.
- srcs must be exactly the 19 groups of builtin_properties::BuiltinGroup
  (builtins.c3 imports every generated module, so a missing one fails to
  compile; an unknown one fails in the generator).
"""

def _builtin_defs_impl(ctx):
    outs = []
    for src in ctx.files.srcs:
        if not src.basename.endswith(".def"):
            fail("builtin_defs: expected a .def file, got " + src.path)
        group = src.basename[:-len(".def")]
        out = ctx.actions.declare_file(ctx.label.name + "/" + group + ".c3")
        ctx.actions.run(
            executable = ctx.executable._generator,
            arguments = [src.path, out.path, group],
            inputs = [src],
            outputs = [out],
            mnemonic = "GenerateDef",
            progress_message = "Generating builtin table %{output}",
        )
        outs.append(out)
    return [DefaultInfo(files = depset(outs))]

builtin_defs = rule(
    implementation = _builtin_defs_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".def"], mandatory = True),
        "_generator": attr.label(
            default = "//tools:generate_def",
            executable = True,
            cfg = "exec",
        ),
    },
    doc = "Generates aro::builtin_defs::<group> C3 modules from Builtins/*.def.",
)
