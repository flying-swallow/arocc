// Port of src/aro/Tree.zig `write`, `dump`, `dumpAttribute` and `dumpNode`
// (source-aware AST printing, the `-fsyntax-only --ast-dump` format of the
// test/cases/ast goldens) — plan 16 stage 1 agent 16.4 `dump`. Part of
// module aro::tree (see tree.c3).
//
// Colors: dumpNode uses std.Io.Terminal colors bright_magenta (TYPE),
// bright_cyan (TAG), bright_blue (IMPLICIT), bright_red (NAME),
// bright_green (LITERAL), bright_yellow (ATTRIBUTE), white and reset.
// `diagnostics::Color` lacks BRIGHT_BLUE and BRIGHT_YELLOW; in NO_COLOR
// mode no escape is written and "implicit " is printed before implicit
// nodes instead.
//
// Stage 0 (contract): signatures only.
module aro::tree;
import aro::tokens, aro::type_store, aro::value, aro::attribute, aro::attribute_map, aro::diagnostics;
import std::io, std::core::dstring;

<*
 Zig `write`: C-like source text for an expression node (casts print
 `(type)` via `print_desugared` unless implicit, paren/comma/binary/unary
 operators, literals by token slice, decl refs by name, builtins, member and
 array access, ...); anything unsupported prints "<node>".
*>
fn void Tree.write(&self, NodeIndex node, DString w)
{
	unreachable("stage 0 stub");
}

<* Zig `dump`: `dump_node(root, 0)` then '\n' for every root decl; flush. *>
fn void? Tree.dump(&self, Terminal term)
{
	unreachable("stage 0 stub");
}

<*
 Zig `dumpAttribute`: `<namespace>::` for STANDARD syntax, the attribute
 name (nothing for the ARO namespace), then its arguments: nothing for
 void payloads, ": <s>" for strings, ": {s|null}" for optional strings,
 ": { field: value, ... }" for struct payloads and ": <any>" otherwise;
 then '\n'.
*>
fn void? Tree.dump_attribute(&self, AttrRef ref, OutStream w)
{
	unreachable("stage 0 stub");
}

<*
 Zig `dumpNode`: indent `level`, "implicit " (no color) / color, the kind
 name, ": " + "(cast kind) " + "'<qt.dump>'" when typed, " lvalue",
 " bitfield", asm qualifiers, " (value: ...)" from value_map (pointer
 values print the compound literal / decl name + offset), the implicit
 return " (value: 0)", '\n', the node's attributes at level + 1, then the
 per-kind children at level + 2 (delta 2, half 1).
*>
fn void? Tree.dump_node(&self, NodeIndex node, uint level, Terminal term)
{
	unreachable("stage 0 stub");
}
