// SymbolStack glue: the context SymbolStack reports diagnostics through.
module aro::parser;
import aro::symbol_stack, aro::type_store;

<* Build the SymbolStack context around this parser; SymbolStack reports through `Diagnostic.@emit(ctx.parser, ...)`. *>
fn symbol_stack::SymbolContext Parser.symbol_context(&self)
{
	return {
		.comp = self.comp,
		.parser = self,
	};
}

<* Zig `p.setTentativeDeclDefinition`. Explicitly guarded: symbol declaration operations must not
 silently discard tentative-definition links when the declaration grammar has not supplied one. *>
fn void Parser.symbol_tentative_definition(&self, type_store::NodeIndex declaration, type_store::NodeIndex definition)
{
	Parser* p = self;
	assert(p.handler && &p.handler.handle_tentative_decl_definition, "declaration completion handler is not bound");
	p.handler.handle_tentative_decl_definition(p, declaration, definition);
}
