// SymbolStack adapter for Parser's token-aware diagnostics and callbacks.
module aro::parser;
import aro::parser_diagnostics, aro::symbol_stack, aro::tokens, aro::type_store;
import std::core::dstring;

<* Build the SymbolStack context around this parser. The completion callback is
 explicitly guarded: symbol declaration operations must not silently discard
 tentative-definition links when the declaration grammar has not supplied one. *>
fn symbol_stack::SymbolContext Parser.symbol_context(&self)
{
	return {
		.comp = self.comp,
		.handler = self,
	};
}

fn void? Parser.symbol_diag(&self, tokens::TokenIndex tok, symbol_stack::SymbolDiag diag, type_store::QualType qt_a, type_store::QualType qt_b) @dynamic
{
	Parser* p = self;
	String name = p.tree.tok_slice(tok);
	parser_diagnostics::ParserDiag parser_diag;
	DString message;
	message.init(tmem);
	switch (diag)
	{
		case MUST_USE_STRUCT:
			parser_diag = parser_diagnostics::ParserDiag.MUST_USE_STRUCT;
			message.appendf("must use 'struct' tag to refer to type '%s'", name);
		case MUST_USE_UNION:
			parser_diag = parser_diagnostics::ParserDiag.MUST_USE_UNION;
			message.appendf("must use 'union' tag to refer to type '%s'", name);
		case MUST_USE_ENUM:
			parser_diag = parser_diagnostics::ParserDiag.MUST_USE_ENUM;
			message.appendf("must use 'enum' tag to refer to type '%s'", name);
		case WRONG_TAG:
			parser_diag = parser_diagnostics::ParserDiag.WRONG_TAG;
			message.appendf("use of '%s' with tag type that does not match previous definition", name);
		case PREVIOUS_DEFINITION:
			parser_diag = parser_diagnostics::ParserDiag.PREVIOUS_DEFINITION;
			message.append_string("previous definition is here");
		case REDEFINITION_OF_TYPEDEF:
			// SymbolStack passes the new typedef's base type first, then the old one.
			return p.err(parser_diagnostics::ParserDiag.REDEFINITION_OF_TYPEDEF, tok,
				p.fmt_qt(qt_a), p.fmt_qt(qt_b));
		case REDEFINITION_DIFFERENT_SYM:
			parser_diag = parser_diagnostics::ParserDiag.REDEFINITION_DIFFERENT_SYM;
			message.appendf("redefinition of '%s' as different kind of symbol", name);
		case REDEFINITION_INCOMPATIBLE:
			parser_diag = parser_diagnostics::ParserDiag.REDEFINITION_INCOMPATIBLE;
			message.appendf("redefinition of '%s' with a different type", name);
		case REDEFINITION:
			parser_diag = parser_diagnostics::ParserDiag.REDEFINITION;
			message.appendf("redefinition of '%s'", name);
		case REDEFINITION_OF_PARAMETER:
			parser_diag = parser_diagnostics::ParserDiag.REDEFINITION_OF_PARAMETER;
			message.appendf("redefinition of parameter '%s'", name);
	}
	return p.emit_parser_diag(parser_diag, message.str_view(), tok);
}

fn void Parser.symbol_tentative_definition(&self, type_store::NodeIndex declaration, type_store::NodeIndex definition) @dynamic
{
	Parser* p = self;
	assert(p.handler && &p.handler.handle_tentative_decl_definition, "declaration completion handler is not bound");
	p.handler.handle_tentative_decl_definition(p, declaration, definition);
}
