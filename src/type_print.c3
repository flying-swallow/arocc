// Port of the printing part of src/aro/TypeStore.zig: QualType.print,
// printNamed, printDesugared, printPrologue/printEpilogue, dump and
// shouldDesugar (with the `Builder.fromType(...).str(...)` it relies on).
// Output goes to an OutStream; write faults propagate.
module aro::type_store;
import aro::compilation, aro::lang_opts, aro::string_interner, std::core::dstring, std::io;

fn void? QualType.print(self, Compilation* comp, OutStream w)
{
	if (self.is_c23_auto())
	{
		w.write("auto")!;
		return;
	}
	if (self.is_auto_type())
	{
		w.write("__auto_type")!;
		return;
	}
	self.print_prologue(comp, false, w)!;
	self.print_epilogue(comp, false, w)!;
}

fn void? QualType.print_named(self, String name, Compilation* comp, OutStream w)
{
	if (self.is_c23_auto())
	{
		io::fprintf(w, "auto %s", name)!;
		return;
	}
	if (self.is_auto_type())
	{
		io::fprintf(w, "__auto_type %s", name)!;
		return;
	}
	bool simple = self.print_prologue(comp, false, w)!;
	if (simple) w.write_byte(' ')!;
	w.write(name)!;
	self.print_epilogue(comp, false, w)!;
}

fn void? QualType.print_desugared(self, Compilation* comp, OutStream w)
{
	self.print_prologue(comp, true, w)!;
	self.print_epilogue(comp, true, w)!;
}

<* Convenience: print into a temp-allocated string. *>
fn String QualType.tprint(self, Compilation* comp)
{
	DString w;
	w.init(tmem);
	self.print(comp, &w)!!;
	return w.str_view();
}

<* Convenience: dump into a temp-allocated string. *>
fn String QualType.tdump(self, Compilation* comp)
{
	DString w;
	w.init(tmem);
	self.dump(comp, &w)!!;
	return w.str_view();
}

fn void? write_ptr_quals(QualType qt, OutStream w) @local
{
	if (qt.is_const) w.write("const")!;
	if (qt.is_volatile)
	{
		if (qt.is_const) w.write_byte(' ')!;
		w.write("volatile")!;
	}
	if (qt.is_restrict)
	{
		if (qt.is_const || qt.is_volatile) w.write_byte(' ')!;
		w.write("restrict")!;
	}
}

fn bool? QualType.print_prologue(self, Compilation* comp, bool desugar, OutStream w)
{
	Type ty = self.get_type(comp);
	bool done = false;
	while (!done)
	{
		switch (ty.tag)
		{
			case POINTER:
				Pointer pointer = ty.pointer;
				bool simple = pointer.child.print_prologue(comp, desugar, w)!;
				if (simple) w.write_byte(' ')!;
				TypeTag child_tag = pointer.child.base(comp).ty.tag;
				if (child_tag == FUNC || child_tag == ARRAY) w.write_byte('(')!;
				w.write_byte('*')!;
				write_ptr_quals(self, w)!;
				if (pointer.nullability != DEFAULT)
				{
					w.write_byte(' ')!;
					w.write(pointer.nullability.str)!;
				}
				return false;
			case FUNC:
				bool simple = ty.func.return_type.print_prologue(comp, desugar, w)!;
				if (simple) w.write_byte(' ')!;
				return false;
			case BLOCK:
				assert(ty.block.func.is(comp, FUNC));
				bool simple = ty.block.func.print_prologue(comp, desugar, w)!;
				w.write(simple ? " ^" : "(^")!;
				write_ptr_quals(self, w)!;
				if (!simple) w.write_byte(')')!;
				return false;
			case ARRAY:
				if (self.is_const) w.write("const ")!;
				if (self.is_volatile) w.write("volatile")!;
				bool simple = ty.array.elem.print_prologue(comp, desugar, w)!;
				if (simple) w.write_byte(' ')!;
				return false;
			case TYPEOF:
				if (desugar)
				{
					ty = ty.type_of.base.get_type(comp);
					continue;
				}
				if (self.is_const && !ty.type_of.base.is_const) w.write("const ")!;
				if (self.is_volatile && !ty.type_of.base.is_volatile) w.write("volatile ")!;
				w.write("typeof(")!;
				ty.type_of.base.print(comp, w)!;
				w.write(")")!;
				return true;
			case TYPEDEF:
				if (desugar)
				{
					ty = ty.type_def.base.get_type(comp);
					continue;
				}
				if (self.is_const) w.write("const ")!;
				if (self.is_volatile) w.write("volatile ")!;
				w.write(ty.type_def.name.lookup(comp))!;
				return true;
			default:
				done = true;
		}
	}
	if (self.is_const) w.write("const ")!;
	if (self.is_volatile) w.write("volatile ")!;

	Type base = self.base(comp).ty;
	switch (base.tag)
	{
		case POINTER:
		case FUNC:
		case ARRAY:
		case TYPEOF:
		case TYPEDEF:
		case BLOCK:
			unreachable();
		case VOID: w.write("void")!;
		case BOOL: w.write(comp.langopts.standard.at_least(C23) ? "bool" : "_Bool")!;
		case NULLPTR_T: w.write("nullptr_t")!;
		case STORAGE_FLOAT: w.write(base.storage_float.name)!;
		case INT: w.write(int_name(base.int_ty))!;
		case BIT_INT:
			io::fprintf(w, "%s _BitInt(%d)", base.bit_int.signedness == SIGNED ? "signed" : "unsigned", base.bit_int.bits)!;
		case FLOAT: w.write(float_name(base.float_ty))!;
		case COMPLEX:
			w.write("_Complex ")!;
			base.complex.print_prologue(comp, desugar, w)!;
		case ATOMIC:
			w.write("_Atomic(")!;
			base.atomic.print_prologue(comp, desugar, w)!;
			base.atomic.print_epilogue(comp, desugar, w)!;
			w.write(")")!;
		case VECTOR:
			switch (base.vector.kind)
			{
				case GENERIC:
					io::fprintf(w, "__attribute__((__vector_size__(%d * sizeof(", base.vector.len)!;
					base.vector.elem.print_prologue(comp, desugar, w)!;
					w.write(")))) ")!;
				case NEON: io::fprintf(w, "__attribute__((neon_vector_type(%d))) ", base.vector.len)!;
				case NEON_POLY: io::fprintf(w, "__attribute__((neon_polyvector_type(%d))) ", base.vector.len)!;
			}
			base.vector.elem.print_prologue(comp, desugar, w)!;
		case STRUCT: io::fprintf(w, "struct %s", base.record.name.lookup(comp))!;
		case UNION: io::fprintf(w, "union %s", base.record.name.lookup(comp))!;
		case ENUM:
			if (base.enum_ty.fixed)
			{
				io::fprintf(w, "enum %s: ", base.enum_ty.name.lookup(comp))!;
				base.enum_ty.tag.print_prologue(comp, desugar, w)!;
			}
			else
			{
				io::fprintf(w, "enum %s", base.enum_ty.name.lookup(comp))!;
			}
	}
	return true;
}

fn String int_name(TypeInt k) => k.name;

fn String float_name(TypeFloat k) => k.name;

fn void? QualType.print_epilogue(self, Compilation* comp, bool desugar, OutStream w)
{
	Type ty = self.get_type(comp);
	while (true)
	{
		switch (ty.tag)
		{
			case POINTER:
				TypeTag child_tag = ty.pointer.child.base(comp).ty.tag;
				if (child_tag == FUNC || child_tag == ARRAY) w.write_byte(')')!;
				ty = ty.pointer.child.get_type(comp);
			case BLOCK:
				ty = ty.block.func.get_type(comp);
			case FUNC:
				Func func = ty.func;
				w.write_byte('(')!;
				foreach (i, param : func.params)
				{
					if (i != 0) w.write(", ")!;
					param.qt.print_prologue(comp, desugar, w)!;
					param.qt.print_epilogue(comp, desugar, w)!;
				}
				if (func.kind != NORMAL)
				{
					if (func.params.len != 0) w.write(", ")!;
					w.write("...")!;
				}
				else if (func.params.len == 0 && !comp.langopts.standard.at_least(C23))
				{
					w.write("void")!;
				}
				w.write_byte(')')!;
				if (func.cc != DEFAULT) io::fprintf(w, " __attribute__((%s))", func.cc.name)!;
				ty = func.return_type.get_type(comp);
			case ARRAY:
				Array array = ty.array;
				w.write_byte('[')!;
				switch (array.len.kind)
				{
					case FIXED:
					case STATIC: io::fprintf(w, "%d", array.len.len)!;
					case INCOMPLETE: break;
					case UNSPECIFIED_VARIABLE: w.write_byte('*')!;
					case VARIABLE: w.write("<expr>")!;
				}
				bool is_static = array.len.kind == STATIC;
				if (is_static) w.write("static")!;
				if (self.is_restrict)
				{
					if (is_static || self.is_const || self.is_volatile) w.write_byte(' ')!;
					w.write("restrict")!;
				}
				w.write_byte(']')!;
				ty = array.elem.get_type(comp);
			case TYPEOF:
				if (!desugar) return;
				ty = ty.type_of.base.get_type(comp);
			case TYPEDEF:
				if (!desugar) return;
				ty = ty.type_def.base.get_type(comp);
			default: return;
		}
	}
}

fn void? dump_params(Func func, Compilation* comp, OutStream w) @local
{
	foreach (i, param : func.params)
	{
		if (i != 0) w.write(", ")!;
		if (param.name != string_interner::EMPTY) io::fprintf(w, "%s: ", param.name.lookup(comp))!;
		param.qt.dump(comp, w)!;
	}
	if (func.kind != NORMAL)
	{
		if (func.params.len != 0) w.write(", ")!;
		w.write("...")!;
	}
	w.write(") ")!;
	if (func.cc != DEFAULT) io::fprintf(w, "cc(%s) ", func.cc.name)!;
	func.return_type.dump(comp, w)!;
}

<* The AST-dump spelling of a type (Zig QualType.dump). *>
fn void? QualType.dump(self, Compilation* comp, OutStream w)
{
	if (self.is_const) w.write("const ")!;
	if (self.is_volatile) w.write("volatile ")!;
	if (self.is_restrict) w.write("restrict ")!;
	if (self.is_invalid())
	{
		w.write("invalid")!;
		return;
	}
	Type ty = self.get_type(comp);
	switch (ty.tag)
	{
		case POINTER:
			Pointer pointer = ty.pointer;
			if (pointer.nullability != DEFAULT)
			{
				w.write(pointer.nullability.str)!;
				w.write_byte(' ')!;
			}
			if (pointer.has_decayed)
			{
				w.write("decayed *")!;
				pointer.decayed.dump(comp, w)!;
			}
			else
			{
				w.write("*")!;
				switch (pointer.bounds)
				{
					case SINGLE: w.write("single ")!;
					case UNSAFE_INDEXABLE: w.write("unsafe_indexable ")!;
					case C: break;
				}
				pointer.child.dump(comp, w)!;
			}
		case FUNC:
			w.write(ty.func.kind == OLD_STYLE ? "kr (" : "fn (")!;
			dump_params(ty.func, comp, w)!;
		case BLOCK:
			Func func = ty.block.func.get(comp, FUNC)!!.func;
			w.write("block (")!;
			dump_params(func, comp, w)!;
		case ARRAY:
			switch (ty.array.len.kind)
			{
				case FIXED: io::fprintf(w, "[%d]", ty.array.len.len)!;
				case STATIC: io::fprintf(w, "[static %d]", ty.array.len.len)!;
				case INCOMPLETE: w.write("[]")!;
				case UNSPECIFIED_VARIABLE: w.write("[*]")!;
				case VARIABLE: w.write("[<expr>]")!;
			}
			ty.array.elem.dump(comp, w)!;
		case VECTOR:
			String kind;
			switch (ty.vector.kind)
			{
				case GENERIC: kind = "vector";
				case NEON: kind = "neon_vector";
				case NEON_POLY: kind = "neon_polyvector";
			}
			io::fprintf(w, "%s(%d, ", kind, ty.vector.len)!;
			ty.vector.elem.dump(comp, w)!;
			w.write(")")!;
		case TYPEOF:
			w.write("typeof(")!;
			if (ty.type_of.has_expr) w.write("<expr>: ")!;
			ty.type_of.base.dump(comp, w)!;
			w.write(")")!;
		case TYPEDEF:
			w.write(ty.type_def.name.lookup(comp))!;
			w.write(": ")!;
			ty.type_def.base.dump(comp, w)!;
		case ENUM:
			io::fprintf(w, "enum %s: ", ty.enum_ty.name.lookup(comp))!;
			if (ty.enum_ty.has_tag)
			{
				ty.enum_ty.tag.dump(comp, w)!;
			}
			else
			{
				w.write("<incomplete>")!;
			}
		default:
			self.unqualified().print(comp, w)!;
	}
}

<* Whether diagnostics should also show the desugared type. *>
fn bool QualType.should_desugar(self, Compilation* comp)
{
	Type ty = self.get_type(comp);
	while (true)
	{
		switch (ty.tag)
		{
			case POINTER: ty = ty.pointer.child.get_type(comp);
			case FUNC:
				foreach (param : ty.func.params)
				{
					if (param.qt.should_desugar(comp)) return true;
				}
				ty = ty.func.return_type.get_type(comp);
			case TYPEOF: return true;
			case TYPEDEF:
				if (try some = specifier_str(comp, ty.type_def.base))
				{
					return some != ty.type_def.name.lookup(comp);
				}
				return true;
			default: return false;
		}
	}
}

<*
 `Builder.fromType(comp, qt).str(comp.langopts)`: the keyword spelling of a
 type built only from specifier keywords, or NO_SPECIFIER_STR (Zig null).
*>
fn String? specifier_str(Compilation* comp, QualType qt)
{
	Type ty = qt.base(comp).ty;
	switch (ty.tag)
	{
		case VOID: return "void";
		case NULLPTR_T: return "nullptr_t";
		case BOOL: return comp.langopts.standard.at_least(C23) ? "bool" : "_Bool";
		case INT: return int_name(ty.int_ty);
		case FLOAT:
			switch (ty.float_ty)
			{
				case BF16:
				case FP16:
				case FLOAT16:
				case FLOAT:
				case DOUBLE:
				case LONG_DOUBLE:
				case FLOAT128: return float_name(ty.float_ty);
				default: return NO_SPECIFIER_STR~;
			}
		case STORAGE_FLOAT: return ty.storage_float.name;
		case COMPLEX:
			Type c = ty.complex.base(comp).ty;
			switch (c.tag)
			{
				case INT:
					switch (c.int_ty)
					{
						case CHAR: return "_Complex char";
						case SCHAR: return "_Complex signed char";
						case UCHAR: return "_Complex unsigned char";
						case SHORT: return "_Complex short";
						case USHORT: return "_Complex unsigned short";
						case INT: return "_Complex int";
						case UINT: return "_Complex unsigned int";
						case LONG: return "_Complex long";
						case ULONG: return "_Complex unsigned long";
						case LONG_LONG: return "_Complex long long";
						case ULONG_LONG: return "_Complex unsigned long long";
						case INT128: return "_Complex __int128";
						case UINT128: return "_Complex unsigned __int128";
						case INT24: return "_Complex __int24";
						case UINT24: return "_Complex unsigned __int24";
					}
				case BIT_INT: return NO_SPECIFIER_STR~;
				case FLOAT:
					switch (c.float_ty)
					{
						case FP16:
						case BF16:
						case DFLOAT32:
						case DFLOAT64:
						case DFLOAT128:
						case DFLOAT64X: unreachable("no complex form");
						case FLOAT16: return "_Complex _Float16";
						case FLOAT: return "_Complex float";
						case DOUBLE: return "_Complex double";
						case LONG_DOUBLE: return "_Complex long double";
						case FLOAT128: return "_Complex __float128";
						default: return NO_SPECIFIER_STR~;
					}
				default: unreachable("complex of a non-arithmetic type");
			}
		default: return NO_SPECIFIER_STR~;
	}
}
