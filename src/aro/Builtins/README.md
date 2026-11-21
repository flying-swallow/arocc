# Builtin tables

## Normal C3 builds

The `.def` files in this directory are inputs to the C3 build. The root
`builtin_defs` declaration lists the input files, and the `builtin_defs` rule
uses `//tools:generate_def` to produce one C3 table module per `.def` file.
Those generated modules are compiled as sources of `//:aro_c3_lib`, which is
used by the production `//:aro_c3` binary.

Build the production compiler with:

```sh
bazel build //:aro_c3
```

Bazel generates the builtin tables as part of this build. Building
`//tools:generate_def` separately only builds the generator executable; the
`builtin_defs` rule supplies each input path, output path, and builtin group
when it runs the generator. The checked-in `.def` files remain the inputs to
this C3 generation step. If a group is added or removed, update the declared
inputs in the root `BUILD.bazel` and the `BuiltinGroup` enum in
`src/frontend/c/builtin_properties.c3`.

## Optional legacy Zig/Clang TableGen refresh

The following workflow is only for intentionally refreshing the `.def` files
from the Zig/Clang TableGen sources. It is legacy maintenance and is not part
of a normal production C3 build.

1. Apply `update.patch` in the `llvm-project` or `zig-bootstrap` repository.
2. Fix any breakage caused by the Zig update.
3. Run the generator from that repository, with `$ARO` set to the path to the
   Arocc repository:

   ```sh
   zig run --dep properties -Mroot=update_builtin_defs.zig -Mproperties=$ARO/src/aro/Builtins/properties.zig -- zig out/host/bin/clang-tblgen $ARO/src/aro/Builtins
   ```

4. Follow any instructions reported by the generator when it encounters
   errors.
5. For the legacy Zig build, add or remove generated `.def` files from
   `Builtins.zig` and `build.zig` as needed. For the C3 build, update the root
   `BUILD.bazel` input list when the set of `.def` groups changes.
6. Manually clean up `common.def`:
   1. Copy the `Special cased builtins` from the old version to the start of
      the new version.
   2. Delete duplicated builtins from the generated portion.
   3. Delete builtins with an empty `param_str`.
   4. Add new headers to `Builtins/properties.zig:headers`.
7. Update `update.patch` if needed.
