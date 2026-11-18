// Initializer grammar and typed initializer construction: `= expr`, brace lists,
// designators and GNU ranges, built into an InitList and converted to tree nodes.
// Element expressions use Parser's own assignment / integer-constant productions;
// test builds may substitute them through `Parser.initializer_test_probe`.
module aro::parser;
import aro::tree, aro::type_store, aro::tokens, aro::tokenizer, aro::init_list;
import aro::parser_result, aro::value, aro::diagnostics, aro::parser_expression, aro::string_interner;
import aro::bigint;
import std::collections::list, std::core::dstring;


struct InitializerRangeSegment
{
	sz path_index;
	ulong start_index;
	ulong end_index;
}

<* Initializer assignment-expression production. Test builds may substitute
   it through `initializer_test_probe`. *>
fn parser_result::Result? Parser.initializer_assign_expr(&self, bool eval)
{
	$if env::TESTING:
		if (self.initializer_test_probe) return self.initializer_test_probe.assignment_expression(self, eval);
	$endif
	return self.assign_expr(eval);
}

<* Initializer integer-constant-expression production (array designators). *>
fn parser_result::Result? Parser.initializer_ice(&self, ConstDeclFoldingMode mode)
{
	$if env::TESTING:
		if (self.initializer_test_probe) return self.initializer_test_probe.integer_constant_expression(self, mode, true);
	$endif
	return self.integer_const_expr(true, mode);
}

fn parser_result::Result? Parser.parse_initializer_value(&self, type_store::QualType target, bool eval = true)
{
	if (!self.is_at(tokenizer::TokenId.L_BRACE))
	{
		tokens::TokenIndex tok = self.tok_i;
		parser_result::Result? parsed = self.initializer_assign_expr(eval);
		if (catch __fault = parsed)
		{
			if (__fault == parser_expression::NO_EXPRESSION)
			{
				// An initializer requires an assignment-expression. Match
				// Parser.zig's expectResult(assignExpr): diagnose the missing
				// expression and return an ordinary parse failure for recovery.
				Diagnostic.EXPECTED_EXPR.@emit(self, self.diag_index())!;
				return PARSING_FAILED~;
			}
			return __fault~;
		}
		parser_result::Result result = parsed;
		if (!target.is_invalid() && target.is(self.comp, type_store::TypeTag.ARRAY))
		{
			// A non-braced array initializer is only accepted as a compatible
			// string literal or array compound literal. Other expressions get the
			// dedicated array-initializer diagnostic and are not scalar-coerced.
			self.coerce_array_initializer(&result, tok, target)!;
		}
		else if (!target.is_invalid())
		{
			if (!(result.coerce_scalar(self, target, tok, parser_result::CoercionContext.INITIALIZATION)!))
			{
				result.qt = type_store::INVALID;
				result.val = value::NONE;
			}
		}
		result.save_value(self);
		return result;
	}

	init_list::InitList il;
	il.init(self.comp.gpa);
	defer il.free();
	tokens::TokenIndex opener = self.tok_i;
	self.advance();
	List{ulong} cursor_path;
	cursor_path.init(self.comp.gpa, 1);
	defer cursor_path.free();
	List{InitializerRangeSegment} range_segments;
	range_segments.init(self.comp.gpa, 0);
	defer range_segments.free();
	List{ulong} range_values;
	range_values.init(self.comp.gpa, 0);
	defer range_values.free();
	List{ulong} range_designator_path;
	range_designator_path.init(self.comp.gpa, 0);
	defer range_designator_path.free();
	cursor_path.push(0);
	bool warned_excess = false;
	bool first = true;
	while (!self.at_eof() && !self.is_at(tokenizer::TokenId.R_BRACE))
	{
		if (!first)
		{
			if (!self.is_at(tokenizer::TokenId.COMMA)) break;
			self.advance();
			if (self.is_at(tokenizer::TokenId.R_BRACE)) break;
		}
		first = false;
		ulong index = cursor_path.len() > 0 ? cursor_path[0] : 0;
		range_segments.clear();
		type_store::QualType child_qt = self.child_type(target, index);
		type_store::QualType designated_qt = target;
		init_list::InitList* selected = &il;
		bool designated = false;
		while (self.is_at(tokenizer::TokenId.L_BRACKET) || self.is_at(tokenizer::TokenId.PERIOD))
		{
			if (!designated) cursor_path.clear();
			designated = true;
			if (self.is_at(tokenizer::TokenId.L_BRACKET))
			{
				tokens::TokenIndex bracket = self.tok_i;
				self.advance();
				tokens::TokenIndex index_tok = self.tok_i;
				parser_result::Result index_result = self.initializer_ice(ConstDeclFoldingMode.GNU_FOLDING_EXTENSION)!;
				if (index_result.val.is_none())
				{
					Diagnostic.EXPECTED_INTEGER_CONSTANT_EXPR.@emit(self, index_tok)!;
					return PARSING_FAILED~;
				}
				if (try converted = index_result.val.to_usz(self.comp)) { index = (ulong)converted; }
				else
				{
					if (value::compare(index_result.val, bigint::CompareOperator.LT, value::ZERO, self.comp))
					{
						Diagnostic.NEGATIVE_ARRAY_DESIGNATOR.@emit(self, bracket + 1,
							self.fmt_value(index_result.val, index_result.qt))!;
					}
					else
					{
						Diagnostic.OOB_ARRAY_DESIGNATOR.@emit(self, bracket + 1,
							self.fmt_value(index_result.val, index_result.qt))!;
					}
					return PARSING_FAILED~;
				}
				if (!designated_qt.is_invalid() && !designated_qt.is(self.comp, type_store::TypeTag.ARRAY))
				{
					Diagnostic.INVALID_ARRAY_DESIGNATOR.@emit(self, bracket,
						self.fmt_qt(designated_qt))!;
					return PARSING_FAILED~;
				}
				bool this_range = self.is_at(tokenizer::TokenId.ELLIPSIS);
				ulong range_end_index = 0;
				tokens::TokenIndex range_end_tok = 0;
				parser_result::Result end_result = { .val = value::NONE };
				end_result.val = value::NONE;
				if (this_range)
				{
					self.advance();
					range_end_tok = self.tok_i;
					parser_result::Result range_end = self.initializer_ice(ConstDeclFoldingMode.GNU_FOLDING_EXTENSION)!;
					end_result = range_end;
					if (end_result.val.is_none())
					{
						Diagnostic.EXPECTED_INTEGER_CONSTANT_EXPR.@emit(self, range_end_tok)!;
						return PARSING_FAILED~;
					}
					if (try converted_end = end_result.val.to_usz(self.comp)) { range_end_index = (ulong)converted_end; }
					else
					{
						if (value::compare(end_result.val, bigint::CompareOperator.LT, value::ZERO, self.comp))
						{
							Diagnostic.NEGATIVE_ARRAY_DESIGNATOR.@emit(self, range_end_tok,
								self.fmt_value(end_result.val, end_result.qt))!;
						}
						else
						{
							Diagnostic.OOB_ARRAY_DESIGNATOR.@emit(self, range_end_tok,
								self.fmt_value(end_result.val, end_result.qt))!;
						}
						return PARSING_FAILED~;
					}
				}
				if (catch self.expect_closing(tokenizer::TokenId.R_BRACKET, bracket)) return PARSING_FAILED~;
				if (try arr = designated_qt.get(self.comp, type_store::TypeTag.ARRAY))
				{
					if (arr.array.len.kind == type_store::ArrayLenKind.FIXED || arr.array.len.kind == type_store::ArrayLenKind.STATIC)
					{
						if (index >= arr.array.len.len)
						{
							Diagnostic.OOB_ARRAY_DESIGNATOR.@emit(self, bracket + 1,
								self.fmt_value(index_result.val, index_result.qt))!;
							return PARSING_FAILED~;
						}
						if (this_range && range_end_index >= arr.array.len.len)
						{
							Diagnostic.OOB_ARRAY_DESIGNATOR.@emit(self, range_end_tok,
								self.fmt_value(end_result.val, end_result.qt))!;
							return PARSING_FAILED~;
						}
					}
				}
				if (this_range && range_end_index < index)
				{
					Diagnostic.ARRAY_DESIGNATOR_RANGE_REVERSED.@emit(self, range_end_tok)!;
					return PARSING_FAILED~;
				}
				child_qt = self.child_type(designated_qt, index);
				designated_qt = child_qt;
				selected = selected.find(index);
				cursor_path.push(index);
				if (this_range)
				{
					// The canonical AST has no range node, so the parsed initializer is
					// copied to each sparse child in the selected interval below.
					range_segments.push({
						.path_index = cursor_path.len() - 1,
						.start_index = index,
						.end_index = range_end_index,
					});
				}
			}
			else
			{
				self.advance();
				if (self.at_eof()) return PARSING_FAILED~;
				String name = self.tree.tok_slice(self.tok_i);
				string_interner::StringId field_name = self.comp.intern_string(name);
				self.advance();
				if (!designated_qt.is_invalid() && !@ok(designated_qt.get_record(self.comp)))
				{
					Diagnostic.INVALID_FIELD_DESIGNATOR.@emit(self, self.tok_i - 2,
						self.fmt_qt(designated_qt))!;
					return PARSING_FAILED~;
				}
				usz field_index = self.field_index(designated_qt, field_name);
				if (field_index == usz::max)
				{
					Diagnostic.NO_SUCH_FIELD_DESIGNATOR.@emit(self, self.tok_i - 1,
						name)!;
					return PARSING_FAILED~;
				}
				index = (ulong)field_index;
				child_qt = self.field_type(designated_qt, field_index);
				designated_qt = child_qt;
				selected = selected.find(index);
				cursor_path.push(index);
			}
		}
		if (range_segments.len() > 0)
		{
			range_designator_path.clear();
			foreach (path_index : cursor_path) range_designator_path.push(path_index);
		}
		bool range_start_initialized = false;
		if (range_segments.len() > 0)
		{
			init_list::InitList* range_start = &il;
			foreach (path_index : range_designator_path) range_start = range_start.find(path_index);
			range_start_initialized = range_start.has_initializer();
		}
		if (designated)
		{
			if (self.is_at(tokenizer::TokenId.EQUAL)) { self.advance(); }
			else { Diagnostic.GNU_MISSING_EQ_DESIGNATOR.@emit(self, self.tok_i)!; }
		}
		tokens::TokenIndex initializer_tok = self.tok_i;
		// Only a braced element needs its own child slot. A plain expression is
		// stored at this list or at a deeper scalar path; an unconditional find
		// here leaves an empty placeholder, which then counts as a prior initializer.
		init_list::InitList* child = selected;
		if (self.is_at(tokenizer::TokenId.L_BRACE))
		{
			type_store::QualType brace_qt = designated ? designated_qt : target;
			if (!designated)
			{
				child = il.find(index);
				ulong brace_index = cursor_path.len() > 0 ? cursor_path[0] : 0;
				ulong limit = self.aggregate_count(target);
				if (self.is_aggregate(target) && brace_index < limit)
				{
					child = il.find(brace_index);
					brace_qt = self.child_type(target, brace_index);
					cursor_path[0] = brace_index + 1;
					while (cursor_path.len() > 1) cursor_path.pop()!!;
				}
				else if (self.is_aggregate(target))
				{
					if (!warned_excess)
					{
						self.err_excess_initializer(target, self.tok_i)!;
						warned_excess = true;
					}
					brace_qt = type_store::INVALID;
				}
			}
			if (child.has_initializer() && !target.is_invalid())
			{
				Diagnostic.INITIALIZER_OVERRIDES.@emit(self, self.tok_i)!;
				Diagnostic.PREVIOUS_INITIALIZER.@emit(self, child.previous_initializer_tok())!;
				child.free();
				child.init(self.comp.gpa);
			}
			parser_result::Result nested = self.parse_into(child, brace_qt, eval)!;
		}
		else
		{
			tokens::TokenIndex expr_tok = self.tok_i;
			parser_result::Result parsed = self.initializer_assign_expr(eval)!;
			parser_result::Result result = parsed;
			if (!designated && !self.is_aggregate(target) && !il.node.is_null())
			{
				if (!warned_excess)
				{
					self.err_excess_initializer(target, expr_tok)!;
					warned_excess = true;
				}
			}
			else if (catch self.find_scalar_initializer(&il, target, result, expr_tok, &cursor_path, 0, &warned_excess)) { return PARSING_FAILED~; }
		}
		if (range_segments.len() > 0)
		{
			// GNU range initialization repeats the parsed value for each selected
			// element. Keep storage sparse for ordinary designators; ranges are
			// materialized because the canonical AST has no range node. Snapshot
			// the entire selected subtree before inserting siblings can move its
			// sparse-list storage.
			init_list::InitList source_copy;
			source_copy.init(self.comp.gpa);
			defer source_copy.free();
			// Parsing the value can grow sparse child lists and invalidate cached
			// pointers. Re-resolve the full designated path before copying.
			init_list::InitList* range_source = &il;
			foreach (path_index : range_designator_path) range_source = range_source.find(path_index);
			source_copy.copy_from(*range_source);

			range_values.clear();
			foreach (segment : range_segments) range_values.push(segment.start_index);
			List{ulong} destination_path;
			destination_path.init(self.comp.gpa, range_designator_path.len());
			defer destination_path.free();
			foreach (path_index : range_designator_path) destination_path.push(path_index);
			bool source_destination = true;
			bool range_override_reported = range_start_initialized;
			while (true)
			{
				for (sz i = 0; i < range_segments.len(); i++)
				{
					destination_path[range_segments[i].path_index] = range_values[i];
				}
				if (!source_destination)
				{
					init_list::InitList* destination = &il;
					foreach (path_index : destination_path) destination = destination.find(path_index);
					if (destination.has_initializer() && !range_override_reported)
					{
						tokens::TokenIndex previous_tok = destination.previous_initializer_tok();
						Diagnostic.INITIALIZER_OVERRIDES.@emit(self, initializer_tok)!;
						Diagnostic.PREVIOUS_INITIALIZER.@emit(self, previous_tok)!;
						range_override_reported = true;
					}
					destination.free();
					destination.init(self.comp.gpa);
					destination.copy_from(source_copy);
				}
				source_destination = false;

				bool advanced = false;
				for (sz i = range_segments.len(); i > 0; i--)
				{
					sz segment_index = i - 1;
					if (range_values[segment_index] < range_segments[segment_index].end_index)
					{
						range_values[segment_index]++;
						for (sz reset_index = segment_index + 1; reset_index < range_segments.len(); reset_index++)
						{
							range_values[reset_index] = range_segments[reset_index].start_index;
						}
						advanced = true;
						break;
					}
				}
				if (!advanced) break;
			}

			// Continue after the final destination in designator order: all
			// earlier ranged coordinates are at their ends, then advance the
			// deepest ranged coordinate by one. Any suffix after that range is
			// not part of the next cursor position.
			sz last_segment_index = range_segments.len() - 1;
			sz continuation_path_index = range_segments[last_segment_index].path_index;
			cursor_path.clear();
			for (sz path_index = 0; path_index < continuation_path_index; path_index++)
			{
				ulong continuation_index = range_designator_path[path_index];
				for (sz segment_index = 0; segment_index < range_segments.len(); segment_index++)
				{
					if (range_segments[segment_index].path_index == path_index)
					{
						continuation_index = range_segments[segment_index].end_index;
						break;
					}
				}
				cursor_path.push(continuation_index);
			}
			ulong last_end_index = range_segments[last_segment_index].end_index;
			cursor_path.push(last_end_index == ulong::max ? ulong::max : last_end_index + 1);
			continue;
		}
	}
	if (catch self.expect_closing(tokenizer::TokenId.R_BRACE, opener)) return PARSING_FAILED~;
	il.tok = opener;
	type_store::NodeIndex node = self.convert_init_list(il, target);
	return { .node = node, .qt = target, .val = value::NONE };
}

<* Apply the dedicated array-expression rules used by both direct array
   initializers and brace-elided array subobjects. Returns true when the target
   is an array and the expression has been handled, including diagnosed cases. *>
fn bool? Parser.coerce_array_initializer(&self, parser_result::Result* item,
	tokens::TokenIndex tok, type_store::QualType target)
{
	if (target.is_invalid()) return false;
	type_store::Array target_array = target.get(self.comp, type_store::TypeTag.ARRAY)!!.array;
	tree::Node expression = item.node.get(&self.tree);
	bool string_literal = expression.kind == tree::NodeKind.STRING_LITERAL_EXPR;
	type_store::Type? source_array = item.qt.get(self.comp, type_store::TypeTag.ARRAY);
	bool array_compound = expression.kind == tree::NodeKind.COMPOUND_LITERAL_EXPR && @ok(source_array);
	if (!string_literal && !array_compound)
	{
		Diagnostic.ARRAY_INIT_STR.@emit(self, tok)!;
		return true;
	}
	if (!@ok(source_array))
	{
		Diagnostic.ARRAY_INIT_STR.@emit(self, tok)!;
		return true;
	}
	type_store::Array source = source_array!!.array;
	type_store::QualType source_elem = source.elem;
	type_store::QualType target_elem = target_array.elem;
	bool compatible = target_elem.eql(source_elem, self.comp) ||
		(string_literal && source_elem.eql(type_store::CHAR, self.comp) &&
			(target_elem.eql(type_store::UCHAR, self.comp) || target_elem.eql(type_store::SCHAR, self.comp))) ||
		(string_literal && source_elem.eql(type_store::UCHAR, self.comp) &&
			(target_elem.eql(type_store::UCHAR, self.comp) || target_elem.eql(type_store::SCHAR, self.comp) || target_elem.eql(type_store::CHAR, self.comp)));
	if (!compatible)
	{
		Diagnostic.INCOMPATIBLE_ARRAY_INIT.@emit(self, tok,
			self.fmt_qt(target), self.fmt_qt(item.qt))!;
		return true;
	}
	if (target_array.len.kind == type_store::ArrayLenKind.FIXED)
	{
		ulong target_len = target_array.len.len;
		if (source.len.kind == type_store::ArrayLenKind.FIXED || source.len.kind == type_store::ArrayLenKind.STATIC)
		{
			ulong source_len = source.len.len;
			if (string_literal)
			{
				// A string's final null code unit may be omitted by the target.
				if (source_len > 0 && source_len - 1 > target_len)
				{
					Diagnostic.STR_INIT_TOO_LONG.@emit(self, tok)!;
				}
			}
			else if (source_len > target_len)
			{
				Diagnostic.ARR_INIT_TOO_LONG.@emit(self, tok,
					self.fmt_qt(target), self.fmt_qt(item.qt))!;
			}
		}
	}
	return true;
}

fn type_store::QualType Parser.child_type(&self, type_store::QualType qt, ulong index)
{
	if (try arr = qt.get(self.comp, type_store::TypeTag.ARRAY)) return arr.array.elem;
	if (try vec = qt.get(self.comp, type_store::TypeTag.VECTOR)) return vec.vector.elem;
	if (try complex = qt.get(self.comp, type_store::TypeTag.COMPLEX)) return complex.complex;
	if (try rec = qt.get_record(self.comp))
	{
		if (index < (ulong)rec.fields.len) return rec.fields[(usz)index].qt;
	}
	return type_store::INVALID;
}

fn ulong Parser.aggregate_count(&self, type_store::QualType qt)
{
	if (try arr = qt.get(self.comp, type_store::TypeTag.ARRAY))
	{
		if (arr.array.len.kind == type_store::ArrayLenKind.FIXED || arr.array.len.kind == type_store::ArrayLenKind.STATIC) return arr.array.len.len;
		return ulong::max;
	}
	if (try vec = qt.get(self.comp, type_store::TypeTag.VECTOR)) return (ulong)vec.vector.len;
	if (qt.is(self.comp, type_store::TypeTag.COMPLEX)) return 2;
	if (try rec = qt.get_record(self.comp)) return (ulong)rec.fields.len;
	return 0;
}

fn bool Parser.is_aggregate(&self, type_store::QualType qt)
{
	return qt.is(self.comp, type_store::TypeTag.ARRAY) || qt.is(self.comp, type_store::TypeTag.VECTOR) ||
		qt.is(self.comp, type_store::TypeTag.COMPLEX) || @ok(qt.get_record(self.comp));
}

fn void? Parser.err_excess_initializer(&self, type_store::QualType qt, tokens::TokenIndex tok)
{
	if (qt.is(self.comp, type_store::TypeTag.ARRAY)) return Diagnostic.EXCESS_ARRAY_INIT.@emit(self, tok);
	if (qt.is(self.comp, type_store::TypeTag.VECTOR)) return Diagnostic.EXCESS_VECTOR_INIT.@emit(self, tok);
	if (@ok(qt.get_record(self.comp)))
	{
		if (qt.is(self.comp, type_store::TypeTag.UNION)) return Diagnostic.EXCESS_UNION_INIT.@emit(self, tok);
		return Diagnostic.EXCESS_STRUCT_INIT.@emit(self, tok);
	}
	return Diagnostic.EXCESS_SCALAR_INIT.@emit(self, tok);
}

<* Place an unbraced expression at the next scalar leaf, advancing the sparse
   cursor outward only after each nested array or record is exhausted. *>
fn bool? Parser.find_scalar_initializer(&self, init_list::InitList* il, type_store::QualType qt, parser_result::Result result, tokens::TokenIndex tok, List{ulong}* path, usz depth, bool* warned_excess)
{
	if (qt.is_invalid()) return true;
	while (path.len() <= (sz)depth) path.push(0);
	ulong index = (*path)[(sz)depth];
	ulong count = self.aggregate_count(qt);
	if (qt.is(self.comp, type_store::TypeTag.ARRAY))
	{
		tree::Node expression = result.node.get(&self.tree);
		bool string_literal = expression.kind == tree::NodeKind.STRING_LITERAL_EXPR;
		bool array_compound_literal = expression.kind == tree::NodeKind.COMPOUND_LITERAL_EXPR && result.qt.is(self.comp, type_store::TypeTag.ARRAY);
		if (!il.has_initializer() && (string_literal || array_compound_literal))
		{
			// The parser owner supplies direct string/array compatibility rules.
			// Accept a whole-array expression only before brace elision has
			// initialized any elements of this sparse list.
			if (self.coerce_array_initializer(&result, tok, qt)!)
			{
				self.store_initializer_result(il, qt, result, tok, false)!;
				return true;
			}
		}
	}
	if (depth > 0 && self.is_aggregate(qt) && result.qt.eql(qt, self.comp))
	{
		self.store_initializer_result(il, qt, result, tok, false)!;
		return true;
	}
	if (self.is_aggregate(qt))
	{
		if (count == 0)
		{
			Diagnostic.EMPTY_AGGREGATE_INIT_BRACES.@emit(self, tok)!;
			return true;
		}
		bool union_member_conflict = qt.is(self.comp, type_store::TypeTag.UNION) &&
			(il.items.len() > 1 || (il.items.len() == 1 && il.items[0].index != index));
		if (!il.node.is_null() || index >= count || union_member_conflict)
		{
			if (!*warned_excess)
			{
				self.err_excess_initializer(qt, tok)!;
				*warned_excess = true;
			}
			return true;
		}
		type_store::QualType child_qt = self.child_type(qt, index);
		init_list::InitList* child = il.find(index);
		bool maybe_complete = self.find_scalar_initializer(child, child_qt, result, tok, path, depth + 1, warned_excess)!;
		if (il.tok == 0) il.tok = tok;
		if (!maybe_complete) return false;
		if (index < ulong::max) (*path)[(sz)depth] = index + 1;
		while (path.len() > (sz)depth + 1) path.pop()!!;
		if (qt.is(self.comp, type_store::TypeTag.UNION)) return true;
		return index < ulong::max && index + 1 >= count;
	}

	self.store_initializer_result(il, qt, result, tok, true)!;
	return true;
}

<* Save one scalar or already-compatible aggregate expression at this sparse
   path. `coerce` is false for whole-object expressions that already match. *>
fn void? Parser.store_initializer_result(&self, init_list::InitList* il, type_store::QualType qt, parser_result::Result result, tokens::TokenIndex tok, bool coerce)
{
	if (coerce && !qt.is_invalid() && !result.coerce_scalar(self, qt, tok, parser_result::CoercionContext.INITIALIZATION)!) result.qt = type_store::INVALID;
	if (il.has_initializer() && !qt.is_invalid())
	{
		Diagnostic.INITIALIZER_OVERRIDES.@emit(self, tok)!;
		Diagnostic.PREVIOUS_INITIALIZER.@emit(self, il.previous_initializer_tok())!;
		// A whole-object replacement supersedes any children written earlier.
		il.free();
		il.init(self.comp.gpa);
	}
	result.save_value(self);
	il.node = result.node.pack();
	il.tok = tok;
}

fn bool InitList.has_initializer(self)
{
	return !self.node.is_null() || self.items.len() != 0;
}

<* Copy a sparse initializer subtree, including the source tokens used for
   later override diagnostics. The destination must be empty. *>
fn void InitList.copy_from(&self, init_list::InitList source)
{
	self.node = source.node;
	self.tok = source.tok;
	foreach (entry : source.items)
	{
		init_list::InitList* child = self.find(entry.index);
		child.copy_from(entry.child);
	}
}

fn tokens::TokenIndex InitList.previous_initializer_tok(self)
{
	if (self.tok != 0) return self.tok;
	if (self.items.len() > 0) return self.items[0].child.previous_initializer_tok();
	return 0;
}

fn usz Parser.field_index(&self, type_store::QualType qt, string_interner::StringId name)
{
	if (try rec = qt.get_record(self.comp))
	{
		for (usz i = 0; i < rec.fields.len; i++) if (rec.fields[i].name == name) return i;
	}
	return usz::max;
}

fn type_store::QualType Parser.field_type(&self, type_store::QualType qt, usz index)
{
	if (try rec = qt.get_record(self.comp)) if (index < rec.fields.len) return rec.fields[index].qt;
	return type_store::INVALID;
}

fn parser_result::Result? Parser.parse_into(&self, init_list::InitList* out, type_store::QualType target, bool eval)
{
	parser_result::Result parsed = self.parse_initializer_value(target, eval)!;
	out.node = parsed.node.pack();
	out.tok = parsed.node.tok(&self.tree);
	return parsed;
}

fn type_store::NodeIndex Parser.default_init_node(&self, type_store::QualType qt, tokens::TokenIndex last_tok)
{
	return self.tree.add_node({ .kind = tree::NodeKind.DEFAULT_INIT_EXPR, .default_init = { .last_tok = last_tok, .qt = qt } });
}

fn type_store::NodeIndex Parser.filler_init_node(&self, type_store::QualType qt, ulong count, tokens::TokenIndex last_tok)
{
	return self.tree.add_node({ .kind = tree::NodeKind.ARRAY_FILLER_EXPR, .array_filler = { .last_tok = last_tok, .qt = qt, .count = count } });
}

<* Convert a sparse parsed list to the canonical initializer AST. This retains
 Zig's source-derived behavior for omitted array/vector elements, incomplete
 array completion, struct defaults, and active union member selection. *>
fn type_store::NodeIndex Parser.convert_init_list(&self, init_list::InitList il, type_store::QualType init_qt)
{
	if (init_qt.is_invalid())
	{
		return self.default_init_node(init_qt, self.tok_i);
	}
	if (!il.node.is_null()) return il.node.unwrap();

	type_store::BaseType base = init_qt.base(self.comp);
	switch (base.ty.tag)
	{
		case type_store::TypeTag.COMPLEX:
		{
			type_store::QualType component_qt = base.ty.complex;
			if (il.items.len() == 0) return self.default_init_node(init_qt, self.tok_i == 0 ? 0 : self.tok_i - 1);
			List{type_store::NodeIndex} items;
			items.init(self.comp.gpa);
			defer items.free();
			foreach (entry : il.items) items.push(self.convert_init_list(entry.child, component_qt));
			return self.tree.add_node({ .kind = tree::NodeKind.ARRAY_INIT_EXPR, .container_init = {
				.l_brace_tok = il.tok, .container_qt = init_qt, .items = items.array_view(),
			} });
		}
		case type_store::TypeTag.VECTOR:
		{
			type_store::Vector vector_ty = base.ty.vector;
			return self.convert_sequence(il, init_qt, vector_ty.elem, (ulong)vector_ty.len, true);
		}
		case type_store::TypeTag.ARRAY:
		{
			type_store::Array array_ty = base.ty.array;
			if (array_ty.len.kind == type_store::ArrayLenKind.VARIABLE || array_ty.len.kind == type_store::ArrayLenKind.UNSPECIFIED_VARIABLE)
			{
				return self.default_init_node(init_qt, self.tok_i);
			}
			bool incomplete = array_ty.len.kind == type_store::ArrayLenKind.INCOMPLETE;
			ulong count = incomplete ? 0 : array_ty.len.len;
			if (incomplete)
			{
				foreach (entry : il.items)
				{
					if (entry.index < ulong::max && entry.index + 1 > count) count = entry.index + 1;
				}
			}
			type_store::QualType completed_qt = init_qt;
			if (incomplete) completed_qt = self.comp.type_store.put(type_store::type_array(array_ty.elem, type_store::ArrayLenKind.FIXED, count));
			return self.convert_sequence(il, completed_qt, array_ty.elem, count, true);
		}
		case type_store::TypeTag.STRUCT:
		{
			type_store::Record record_ty = base.ty.record;
			List{type_store::NodeIndex} items;
			items.init(self.comp.gpa);
			defer items.free();
			usz item_index = 0;
			for (usz i = 0; i < record_ty.fields.len; i++)
			{
				type_store::RecordField field = record_ty.fields[i];
				while (item_index < (usz)il.items.len() && il.items[(sz)item_index].index < (ulong)i) item_index++;
				if (item_index < (usz)il.items.len() && il.items[(sz)item_index].index == (ulong)i)
				{
					items.push(self.convert_init_list(il.items[(sz)item_index].child, field.qt));
					item_index++;
				}
				else { items.push(self.default_init_node(field.qt, il.tok)); }
			}
			return self.tree.add_node({ .kind = tree::NodeKind.STRUCT_INIT_EXPR, .container_init = {
				.l_brace_tok = il.tok, .container_qt = init_qt, .items = items.array_view(),
			} });
		}
		case type_store::TypeTag.UNION:
		{
			type_store::Record record_ty = base.ty.record;
			if (record_ty.fields.len == 0) return self.tree.add_node({ .kind = tree::NodeKind.UNION_INIT_EXPR, .union_init = {
				.l_brace_tok = il.tok, .union_qt = init_qt, .field_index = 0, .initializer = type_store::NODE_NULL,
			} });
			ulong active = 0;
			type_store::NodeIndex value = self.default_init_node(record_ty.fields[0].qt, il.tok);
			if (il.items.len() > 0 && il.items[0].index < (ulong)record_ty.fields.len)
			{
				active = il.items[0].index;
				value = self.convert_init_list(il.items[0].child, record_ty.fields[(usz)active].qt);
			}
			return self.tree.add_node({ .kind = tree::NodeKind.UNION_INIT_EXPR, .union_init = {
				.l_brace_tok = il.tok, .union_qt = init_qt, .field_index = (uint)active, .initializer = value.pack(),
			} });
		}
		default: return self.default_init_node(init_qt, self.tok_i);
	}
}

fn type_store::NodeIndex Parser.convert_sequence(&self, init_list::InitList il, type_store::QualType container_qt, type_store::QualType elem_qt, ulong count, bool add_filler)
{
	List{type_store::NodeIndex} items;
	items.init(self.comp.gpa);
	defer items.free();
	ulong cursor = 0;
	foreach (entry : il.items)
	{
		if (entry.index >= count) continue;
		if (entry.index > cursor && add_filler) items.push(self.filler_init_node(elem_qt, entry.index - cursor, self.tok_i == 0 ? 0 : self.tok_i - 1));
		items.push(self.convert_init_list(entry.child, elem_qt));
		cursor = entry.index + 1;
	}
	if (add_filler && cursor < count) items.push(self.filler_init_node(elem_qt, count - cursor, self.tok_i == 0 ? 0 : self.tok_i - 1));
	return self.tree.add_node({ .kind = tree::NodeKind.ARRAY_INIT_EXPR, .container_init = {
		.l_brace_tok = il.tok, .container_qt = container_qt, .items = items.array_view(),
	} });
}

<* Construct the compound-literal AST node once a caller has parsed its type
 and initializer. Parsing the ambiguous `(type-name){...}` prefix and storage
 duration belongs to the primary-expression grammar callback. *>
fn type_store::NodeIndex Parser.compound_literal_node(&self, tokens::TokenIndex l_paren, type_store::QualType qt, type_store::NodeIndex initializer, tree::CompoundLiteralStorageClass storage = tree::CompoundLiteralStorageClass.AUTO, bool thread_local = false)
{
	return self.tree.add_node({ .kind = tree::NodeKind.COMPOUND_LITERAL_EXPR, .compound_literal = {
		.l_paren_tok = l_paren, .qt = qt, .thread_local = thread_local,
		.storage_class = storage, .initializer = initializer,
	} });
}
