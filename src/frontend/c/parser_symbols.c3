// SymbolStack glue: parser hooks SymbolStack calls back into.
module aro::frontend::c::parser;
import aro::frontend::c::symbol_stack, aro::frontend::c::type_store;

<* Zig `p.setTentativeDeclDefinition`. Explicitly guarded: symbol declaration operations must not
 silently discard tentative-definition links when the declaration grammar has not supplied one. *>
fn void Parser.symbol_tentative_definition(&self, type_store::NodeIndex declaration, type_store::NodeIndex definition)
{
	Parser* p = self;
	assert(p.handler && &p.handler.handle_tentative_decl_definition, "declaration completion handler is not bound");
	p.handler.handle_tentative_decl_definition(p, declaration, definition);
}
