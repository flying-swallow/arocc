// Complete C front-end parser wiring: declaration/statement grammar from
// DeclarationParser plus the builtin, compound-literal and statement-expression
// extension hooks. Shared by the CLI driver and the migration frontend probe.
module aro::parser_frontend;
import aro::parser, aro::parser_result, aro::parser_declaration, aro::parser_builtin, aro::parser_postfix;
import aro::builtin_call, aro::tokens, aro::type_store;

<*
 IParserHandler for a full parse. Lives next to the Parser (normally on the
 same stack frame) and must outlive it. Call `bind` after `Parser.init`
 and before `Parser.parse`.
*>
struct FrontendHandler (parser::IParserHandler)
{
	parser_declaration::DeclarationParser declarations;
	parser_builtin::BuiltinParser builtin;
	parser_postfix::PostfixParser postfix;
}

<* Install this handler on an initialized `p` and bind the initializer seam. *>
fn void FrontendHandler.bind(&self, parser::Parser* p)
{
	*self = {};
	self.builtin = {
		.parser = p,
		.context = (void*)self,
		.assignment_expression = &assignment_expression,
		.integer_constant_expression = &integer_constant_expression,
	};
	self.postfix = { .parser = p, .context = (void*)self };
	self.declarations = {
		.statements = {
			.context = (void*)self,
			.expression = &statement_expression,
			.integer_constant_expression = &integer_constant_expression,
			.has_integer_constant_expression = true,
		},
		.implicit_typedefs = &parser_declaration::implicit_typedef_prelude,
		.has_implicit_typedefs = true,
	};
	p.handler = self;
	p.bind_initializer_parser((void*)self, &assignment_expression, &initializer_integer_constant_expression);
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
	self.builtin.parser = p;
	return parser_builtin::builtin_primary_expression((void*)&self.builtin, p, eval);
}

fn parser_result::Result? FrontendHandler.handle_builtin_call(&self, parser::Parser* p, type_store::NodeIndex callee,
	tokens::TokenIndex l_paren, type_store::NodeIndex[] args, bool eval) @dynamic
{
	return builtin_call::dispatch(null, p, callee, l_paren, args, eval);
}

fn parser_result::Result? FrontendHandler.handle_compound_literal_primary(&self, parser::Parser* p,
	tokens::TokenIndex opening_tok, type_store::QualType qt, bool eval) @dynamic
{
	self.postfix.parser = p;
	return self.postfix.parse_compound_literal(opening_tok, qt, eval: eval);
}

fn type_store::NodeIndex? FrontendHandler.handle_statement_expression_body(&self, parser::Parser* p, bool eval) @dynamic
{
	self.declarations.statements.parser = p;
	return self.declarations.statements.parse_body(false);
}

// Sub-parser adapters: route back into Parser's composed expression entry points.
fn parser_result::Result? assignment_expression(void* context, parser::Parser* p, bool eval) @local
	=> p.assign_expr(eval);

fn parser_result::Result? integer_constant_expression(void* context, parser::Parser* p,
	parser::ConstDeclFoldingMode mode, bool eval) @local
	=> p.integer_const_expr(eval, mode);

fn parser_result::Result? initializer_integer_constant_expression(void* context, parser::Parser* p,
	parser::ConstDeclFoldingMode mode) @local
	=> p.integer_const_expr(true, mode);

fn parser_result::Result? statement_expression(void* context, parser::Parser* p, bool eval) @local
	=> p.expr(eval);
