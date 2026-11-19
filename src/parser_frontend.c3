// Complete C front-end parser wiring: declaration/statement grammar from
// DeclarationParser plus the builtin and statement-expression
// extension hooks. Shared by the CLI driver and the migration frontend probe.
module aro::parser_frontend;
import aro::parser, aro::parser_result, aro::parser_declaration, aro::parser_builtin;
import aro::builtin_call, aro::tokens, aro::type_store;

<*
 IParserHandler for a full parse. Lives next to the Parser (normally on the
 same stack frame) and must outlive it. Call `bind` after `Parser.init`
 and before `Parser.parse`.
*>
struct FrontendHandler (parser::IParserHandler, parser::IExpressionGrammar)
{
	parser_declaration::DeclarationParser declarations;
	parser_builtin::BuiltinParser builtin;
}

<* Install this handler on an initialized `p` and bind the initializer seam. *>
fn void FrontendHandler.bind(&self, parser::Parser* p)
{
	*self = {};
	self.builtin = { .parser = p, .expressions = self };
	self.declarations = {
		.statements = { .expressions = self },
		.implicit_typedef_prelude = true,
	};
	p.handler = self;
}

// Grammar hooks forward to the declaration grammar.
fn void? FrontendHandler.handle_declaration(&self, parser::Parser* p) @dynamic
	=> self.declarations.handle_declaration(p);
fn void? FrontendHandler.handle_type_name(&self, parser::Parser* p) @dynamic
	=> self.declarations.handle_type_name(p);
fn type_store::QualType? FrontendHandler.handle_typed_type_name(&self, parser::Parser* p) @dynamic
	=> self.declarations.handle_typed_type_name(p);
fn parser::TypeNameProbe? FrontendHandler.handle_typed_type_name_probe(&self, parser::Parser* p) @dynamic
	=> self.declarations.handle_typed_type_name_probe(p);
fn void? FrontendHandler.handle_body(&self, parser::Parser* p) @dynamic
	=> self.declarations.handle_body(p);
fn void? FrontendHandler.handle_implicit_typedefs(&self, parser::Parser* p) @dynamic
	=> self.declarations.handle_implicit_typedefs(p);
fn void FrontendHandler.handle_tentative_decl_definition(&self, parser::Parser* p,
	type_store::NodeIndex declaration, type_store::NodeIndex definition) @dynamic
	=> self.declarations.handle_tentative_decl_definition(p, declaration, definition);

fn bool? FrontendHandler.is_recoverable_parse_fault(&self, parser::Parser* p, fault parse_fault) @dynamic
	=> self.declarations.is_recoverable_parse_fault(p, parse_fault);

// Expression extension hooks.
fn parser_result::Result? FrontendHandler.handle_builtin_primary_expression(&self, parser::Parser* p, bool eval) @dynamic
{
	return self.builtin.parse_builtin_primary(p, eval);
}

fn parser_result::Result? FrontendHandler.handle_builtin_call(&self, parser::Parser* p, type_store::NodeIndex callee,
	tokens::TokenIndex l_paren, type_store::NodeIndex[] args, bool eval) @dynamic
{
	return builtin_call::dispatch(null, p, callee, l_paren, args, eval);
}

fn type_store::NodeIndex? FrontendHandler.handle_statement_expression_body(&self, parser::Parser* p, bool eval) @dynamic
{
	return self.declarations.statements.parse_body(p, false);
}

// IExpressionGrammar: Parser's composed expression entry points.
fn parser_result::Result? FrontendHandler.expression(&self, parser::Parser* p, bool eval) @dynamic
	=> p.expr(eval);
fn parser_result::Result? FrontendHandler.assignment_expression(&self, parser::Parser* p, bool eval) @dynamic
	=> p.assign_expr(eval);
fn parser_result::Result? FrontendHandler.integer_constant_expression(&self, parser::Parser* p,
	parser::ConstDeclFoldingMode mode, bool eval) @dynamic
	=> p.integer_const_expr(eval, mode);
