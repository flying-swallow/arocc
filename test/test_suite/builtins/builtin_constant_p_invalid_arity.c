// #skip: diagnostics differ (aro_c3 gap)
// Source-derived from the invalid-arity cases in // #error@47: expected 1 argument(s) got 0
// test/cases/builtin_constant_p.c. This also pins the diagnostic to the
// closing parenthesis that completes the malformed call.
/** manifest:
syntax

builtin_constant_p_invalid_arity.c:1:47: error: expected 1 argument(s) got 0
*/
int probe(void) { return __builtin_constant_p(); }
