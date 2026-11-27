// C3 language frontend: a port of c3c (lexer, parser, sema) lowering to
// aro::backend::ir. Codegen follows the design of c3c's C backend
// (src/compiler/c_codegen*.c) but emits IR instead of C text.
//
// Isolation: nothing under src/frontend/c3 may reference aro::frontend::c::*
// or aro::api (checked by //aro_cc/test/unit/c3:isolation_test). Shared layers only:
// aro::backend::*, aro::target, aro::bigint, aro::value_interner,
// aro::primitive_value, aro::string_interner, aro::source.
module aro::frontend::c3;

<* c3c revision this frontend is ported from (~/projects/c3c). *>
const String C3C_REFERENCE_REV = "54bab366a";
