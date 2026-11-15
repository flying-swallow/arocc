module attribute_names_tests;
import aro::attribute;
import aro::tokenizer;

// Expected names and aliases are source-derived from src/aro/Attribute.zig.

fn void normalize_wrapped_names() @test
{
	assert(attribute::normalize("__deprecated__") == "deprecated");
	assert(attribute::normalize("____") == "");
	assert(attribute::normalize("__x") == "__x");
	assert(attribute::normalize("x__") == "x__");
	assert(attribute::normalize("plain") == "plain");
}

fn void standard_names_and_vendor_aliases() @test
{
	Namespaced? standard = attribute::namespaced_from_string(STANDARD, false, "", "__nodiscard__");
	assert(@ok(standard) && standard!!.ns == STANDARD && standard!!.standard == NODISCARD);
	Namespaced? gnu = attribute::namespaced_from_string(STANDARD, true, "__gnu__", "__aligned__");
	assert(@ok(gnu) && gnu!!.ns == GNU && gnu!!.gnu == ALIGNED);
	Namespaced? clang = attribute::namespaced_from_string(STANDARD, true, "clang", "availability");
	assert(@ok(clang) && clang!!.ns == CLANG && clang!!.clang == AVAILABILITY);
	assert(@catch(attribute::namespaced_from_string(STANDARD, true, "aro", "anything")) == attribute::UNKNOWN_ATTRIBUTE);
}

fn void syntax_names_and_invalid_pairs() @test
{
	Namespaced? gnu = attribute::namespaced_from_string(GNU, false, "", "__format__");
	assert(@ok(gnu) && gnu!!.ns == GNU && gnu!!.gnu == FORMAT);
	Namespaced? declspec = attribute::namespaced_from_string(DECLSPEC, false, "", "__spectre__");
	assert(@ok(declspec) && declspec!!.ns == DECLSPEC && declspec!!.declspec == SPECTRE);
	assert(@catch(attribute::namespaced_from_string(STANDARD, false, "", "not_an_attribute")) == attribute::UNKNOWN_ATTRIBUTE);
	assert(@catch(attribute::namespaced_from_string(GNU, false, "", "not_an_attribute")) == attribute::UNKNOWN_ATTRIBUTE);
	assert(@catch(attribute::namespaced_from_string(DECLSPEC, false, "", "aligned")) == attribute::UNKNOWN_ATTRIBUTE);
	assert(@catch(attribute::namespaced_from_string(STANDARD, true, "unknown", "nodiscard")) == attribute::UNKNOWN_ATTRIBUTE);
	assert(@catch(attribute::namespaced_from_string(STANDARD, true, "gnu", "unknown")) == attribute::UNKNOWN_ATTRIBUTE);
}

fn void identifier_args_and_visibility_alias() @test
{
	Namespaced access = attribute::namespaced_from_string(GNU, false, "", "access")!!;
	assert(access.has_identifier_arg());
	Namespaced ordinary = attribute::namespaced_from_string(GNU, false, "", "aligned")!!;
	assert(!ordinary.has_identifier_arg());
	assert(attribute::visibility_from_string("internal")!! == HIDDEN);
	assert(attribute::visibility_from_string("protected")!! == PROTECTED);
	assert(@catch(attribute::visibility_from_string("invalid")) == attribute::UNKNOWN_VISIBILITY);
}

fn void namespaced_keyword_name_and_equality() @test
{
	Namespaced asm_name = attribute::namespaced_from_keyword(KEYWORD_ASM1);
	Namespaced also_asm = attribute::namespaced_from_keyword(KEYWORD_ASM2);
	assert(asm_name.eq(also_asm));
	assert(asm_name.name() == "asm_label");
	assert(!asm_name.eq(attribute::namespaced_from_keyword(KEYWORD_ALIGNAS)));
	assert(attribute::namespaced_from_keyword(KEYWORD_C23_ALIGNAS).name() == "alignas");
}
