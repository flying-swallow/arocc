# c3c test corpus

The files in `test_suite/` are copied without modification from
`/Users/michaelpollind/Documents/c3c/test/test_suite` at c3c revision
`bfb6a64dcae10277f7e74767d1a106b187579ed4` (1,788 `.c3` and `.c3t`
files). They are covered by the upstream MIT license in `LICENSE.c3c`.

`runner.py` is an Aro adapter. It runs source and diagnostic checks through
`aro_c3c --check`. Cases requiring code generation or unsupported compiler
options fail as `unsupported`, so the suite is expected to be red while those
features are being implemented. Upstream `#skip` directives remain skips.

Run the complete gate with `bazel test //aro_c3c:all` or one area with
`bazel test //aro_c3c:area_lexing`.
