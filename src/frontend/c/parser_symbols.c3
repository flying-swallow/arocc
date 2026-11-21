// SymbolStack glue: parser hooks SymbolStack calls back into.
module aro::frontend::c::parser;
import aro::frontend::c::symbol_stack, aro::frontend::c::type_store, aro::frontend::c::parser_declaration;

<* Zig `p.setTentativeDeclDefinition`. Explicitly guarded: symbol declaration operations must not
 silently discard tentative-definition links when the declaration grammar has not supplied one. *>
fn void Parser.symbol_tentative_definition(&self, type_store::NodeIndex declaration, type_store::NodeIndex definition)
{
	Parser* p = self;
	$if env::TESTING:
		if (p.test_probe && &p.test_probe.handle_tentative_decl_definition)
		{
			p.test_probe.handle_tentative_decl_definition(p, declaration, definition);
			return;
		}
	$endif
	p.declarations.handle_tentative_decl_definition(p, declaration, definition);
}
