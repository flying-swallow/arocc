// Port of the printing part of src/aro/TypeStore.zig: QualType.print,
// printNamed, printDesugared, printPrologue/printEpilogue, dump and
// shouldDesugar (with the `Builder.fromType(...).str(...)` it relies on).
// Output is appended to a DString.
module aro::type_store;
import aro::compilation, aro::lang_opts, aro::string_interner, std::core::dstring;

fn void QualType.print(self, Compilation* comp, DString w)
{
	if (self.is_c23_auto())
	{
		w.append_string("auto");
		return;
	}
	if (self.is_auto_type())
	{
		w.append_string("__auto_type");
		return;
	}
	self.print_prologue(comp, false, w);
	self.print_epilogue(comp, false, w);
}

fn void QualType.print_named(self, String name, Compilation* comp, DString w)
{
	if (self.is_c23_auto())
	{
		w.appendf("auto %s", name);
		return;
	}
	if (self.is_auto_type())
	{
		w.appendf("__auto_type %s", name);
		return;
	}
	bool simple = self.print_prologue(comp, false, w);
	if (simple) w.append_char(' ');
	w.append_string(name);
	self.print_epilogue(comp, false, w);
}

fn void QualType.print_desugared(self, Compilation* comp, DString w)
{
	self.print_prologue(comp, true, w);
	self.print_epilogue(comp, true, w);
}

<* Convenience: print into a temp-allocated string. *>
fn String QualType.tprint(self, Compilation* comp)
{
	DString w;
	w.init(tmem);
	self.print(comp, w);
	return w.str_view();
}

<* Convenience: dump into a temp-allocated string. *>
fn String QualType.tdump(self, Compilation* comp)
{
	DString w;
	w.init(tmem);
	self.dump(comp, w);
	return w.str_view();
}

fn void write_ptr_quals(QualType qt, DString w) @local
{
	if (qt.is_const) w.append_string("const");
	if (qt.is_volatile)
	{
		if (qt.is_const) w.append_char(' ');
		w.append_string("volatile");
	}
	if (qt.is_restrict)
	{
		if (qt.is_const || qt.is_volatile) w.append_char(' ');
		w.append_string("restrict");
	}
}

fn bool QualType.print_prologue(self, Compilation* comp, bool desugar, DString w)
{
	Type ty = self.get_type(comp);
	bool done = false;
	while (!done)
	{
		switch (ty.tag)
		{
			case POINTER:
				Pointer pointer = ty.pointer;
				bool simple = pointer.child.print_prologue(comp, desugar, w);
				if (simple) w.append_char(' ');
				TypeTag child_tag = pointer.child.base(comp).ty.tag;
				if (child_tag == FUNC || child_tag == ARRAY) w.append_char('(');
				w.append_char('*');
				write_ptr_quals(self, w);
				if (pointer.nullability != DEFAULT)
				{
					w.append_char(' ');
					w.append_string(pointer.nullability.str);
				}
				return false;
			case FUNC:
				bool simple = ty.func.return_type.print_prologue(comp, desugar, w);
				if (simple) w.append_char(' ');
				return false;
			case BLOCK:
				assert(ty.block.func.is(comp, FUNC));
				bool simple = ty.block.func.print_prologue(comp, desugar, w);
				w.append_string(simple ? " ^" : "(^");
				write_ptr_quals(self, w);
				if (!simple) w.append_char(')');
				return false;
			case ARRAY:
				if (self.is_const) w.append_string("const ");
				if (self.is_volatile) w.append_string("volatile");
				bool simple = ty.array.elem.print_prologue(comp, desugar, w);
				if (simple) w.append_char(' ');
				return false;
			case TYPEOF:
				if (desugar)
				{
					ty = ty.type_of.base.get_type(comp);
					continue;
				}
				if (self.is_const && !ty.type_of.base.is_const) w.append_string("const ");
				if (self.is_volatile && !ty.type_of.base.is_volatile) w.append_string("volatile ");
				w.append_string("typeof(");
				ty.type_of.base.print(comp, w);
				w.append_string(")");
				return true;
			case TYPEDEF:
				if (desugar)
				{
					ty = ty.type_def.base.get_type(comp);
					continue;
				}
				if (self.is_const) w.append_string("const ");
				if (self.is_volatile) w.append_string("volatile ");
				w.append_string(ty.type_def.name.lookup(comp));
				return true;
			default:
				done = true;
		}
	}
	if (self.is_const) w.append_string("const ");
	if (self.is_volatile) w.append_string("volatile ");

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
		case VOID: w.append_string("void");
		case BOOL: w.append_string(comp.langopts.standard.at_least(C23) ? "bool" : "_Bool");
		case NULLPTR_T: w.append_string("nullptr_t");
		case STORAGE_FLOAT: w.append_string(base.storage_float.name);
		case INT: w.append_string(int_name(base.int_ty));
		case BIT_INT:
			w.appendf("%s _BitInt(%d)", base.bit_int.signedness == SIGNED ? "signed" : "unsigned", base.bit_int.bits);
		case FLOAT: w.append_string(float_name(base.float_ty));
		case COMPLEX:
			w.append_string("_Complex ");
			base.complex.print_prologue(comp, desugar, w);
		case ATOMIC:
			w.append_string("_Atomic(");
			base.atomic.print_prologue(comp, desugar, w);
			base.atomic.print_epilogue(comp, desugar, w);
			w.append_string(")");
		case VECTOR:
			switch (base.vector.kind)
			{
				case GENERIC:
					w.appendf("__attribute__((__vector_size__(%d * sizeof(", base.vector.len);
					base.vector.elem.print_prologue(comp, desugar, w);
					w.append_string(")))) ");
				case NEON: w.appendf("__attribute__((neon_vector_type(%d))) ", base.vector.len);
				case NEON_POLY: w.appendf("__attribute__((neon_polyvector_type(%d))) ", base.vector.len);
			}
			base.vector.elem.print_prologue(comp, desugar, w);
		case STRUCT: w.appendf("struct %s", base.record.name.lookup(comp));
		case UNION: w.appendf("union %s", base.record.name.lookup(comp));
		case ENUM:
			if (base.enum_ty.fixed)
			{
				w.appendf("enum %s: ", base.enum_ty.name.lookup(comp));
				base.enum_ty.tag.print_prologue(comp, desugar, w);
			}
			else
			{
				w.appendf("enum %s", base.enum_ty.name.lookup(comp));
			}
	}
	return true;
}

fn String int_name(TypeInt k)
{
	switch (k)
	{
		case CHAR: return "char";
		case SCHAR: return "signed char";
		case UCHAR: return "unsigned char";
		case SHORT: return "short";
		case USHORT: return "unsigned short";
		case INT: return "int";
		case UINT: return "unsigned int";
		case LONG: return "long";
		case ULONG: return "unsigned long";
		case LONG_LONG: return "long long";
		case ULONG_LONG: return "unsigned long long";
		case INT128: return "__int128";
		case UINT128: return "unsigned __int128";
		case INT24: return "__int24";
		case UINT24: return "unsigned __int24";
	}
}

fn String float_name(TypeFloat k)
{
	switch (k)
	{
		case BF16: return "__bf16";
		case FP16: return "__fp16";
		case FLOAT16: return "_Float16";
		case FLOAT: return "float";
		case DOUBLE: return "double";
		case LONG_DOUBLE: return "long double";
		case FLOAT128: return "__float128";
		case FLOAT32: return "_Float32";
		case FLOAT64: return "_Float64";
		case FLOAT32X: return "_Float32x";
		case FLOAT64X: return "_Float64x";
		case FLOAT128X: return "_Float128x";
		case DFLOAT32: return "_Decimal32";
		case DFLOAT64: return "_Decimal64";
		case DFLOAT128: return "_Decimal128";
		case DFLOAT64X: return "_Decimal64x";
	}
}

fn void QualType.print_epilogue(self, Compilation* comp, bool desugar, DString w)
{
	Type ty = self.get_type(comp);
	while (true)
	{
		switch (ty.tag)
		{
			case POINTER:
				TypeTag child_tag = ty.pointer.child.base(comp).ty.tag;
				if (child_tag == FUNC || child_tag == ARRAY) w.append_char(')');
				ty = ty.pointer.child.get_type(comp);
			case BLOCK:
				ty = ty.block.func.get_type(comp);
			case FUNC:
				Func func = ty.func;
				w.append_char('(');
				foreach (i, param : func.params)
				{
					if (i != 0) w.append_string(", ");
					param.qt.print_prologue(comp, desugar, w);
					param.qt.print_epilogue(comp, desugar, w);
				}
				if (func.kind != NORMAL)
				{
					if (func.params.len != 0) w.append_string(", ");
					w.append_string("...");
				}
				else if (func.params.len == 0 && !comp.langopts.standard.at_least(C23))
				{
					w.append_string("void");
				}
				w.append_char(')');
				if (func.cc != DEFAULT) w.appendf(" __attribute__((%s))", func.cc.name);
				ty = func.return_type.get_type(comp);
			case ARRAY:
				Array array = ty.array;
				w.append_char('[');
				switch (array.len.kind)
				{
					case FIXED:
					case STATIC: w.appendf("%d", array.len.len);
					case INCOMPLETE: break;
					case UNSPECIFIED_VARIABLE: w.append_char('*');
					case VARIABLE: w.append_string("<expr>");
				}
				bool is_static = array.len.kind == STATIC;
				if (is_static) w.append_string("static");
				if (self.is_restrict)
				{
					if (is_static || self.is_const || self.is_volatile) w.append_char(' ');
					w.append_string("restrict");
				}
				w.append_char(']');
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

fn void dump_params(Func func, Compilation* comp, DString w) @local
{
	foreach (i, param : func.params)
	{
		if (i != 0) w.append_string(", ");
		if (param.name != string_interner::EMPTY) w.appendf("%s: ", param.name.lookup(comp));
		param.qt.dump(comp, w);
	}
	if (func.kind != NORMAL)
	{
		if (func.params.len != 0) w.append_string(", ");
		w.append_string("...");
	}
	w.append_string(") ");
	if (func.cc != DEFAULT) w.appendf("cc(%s) ", func.cc.name);
	func.return_type.dump(comp, w);
}

<* The AST-dump spelling of a type (Zig QualType.dump). *>
fn void QualType.dump(self, Compilation* comp, DString w)
{
	if (self.is_const) w.append_string("const ");
	if (self.is_volatile) w.append_string("volatile ");
	if (self.is_restrict) w.append_string("restrict ");
	if (self.is_invalid())
	{
		w.append_string("invalid");
		return;
	}
	Type ty = self.get_type(comp);
	switch (ty.tag)
	{
		case POINTER:
			Pointer pointer = ty.pointer;
			if (pointer.nullability != DEFAULT)
			{
				w.append_string(pointer.nullability.str);
				w.append_char(' ');
			}
			if (pointer.has_decayed)
			{
				w.append_string("decayed *");
				pointer.decayed.dump(comp, w);
			}
			else
			{
				w.append_string("*");
				switch (pointer.bounds)
				{
					case SINGLE: w.append_string("single ");
					case UNSAFE_INDEXABLE: w.append_string("unsafe_indexable ");
					case C: break;
				}
				pointer.child.dump(comp, w);
			}
		case FUNC:
			w.append_string(ty.func.kind == OLD_STYLE ? "kr (" : "fn (");
			dump_params(ty.func, comp, w);
		case BLOCK:
			Func func = ty.block.func.get(comp, FUNC)!!.func;
			w.append_string("block (");
			dump_params(func, comp, w);
		case ARRAY:
			switch (ty.array.len.kind)
			{
				case FIXED: w.appendf("[%d]", ty.array.len.len);
				case STATIC: w.appendf("[static %d]", ty.array.len.len);
				case INCOMPLETE: w.append_string("[]");
				case UNSPECIFIED_VARIABLE: w.append_string("[*]");
				case VARIABLE: w.append_string("[<expr>]");
			}
			ty.array.elem.dump(comp, w);
		case VECTOR:
			String kind;
			switch (ty.vector.kind)
			{
				case GENERIC: kind = "vector";
				case NEON: kind = "neon_vector";
				case NEON_POLY: kind = "neon_polyvector";
			}
			w.appendf("%s(%d, ", kind, ty.vector.len);
			ty.vector.elem.dump(comp, w);
			w.append_string(")");
		case TYPEOF:
			w.append_string("typeof(");
			if (ty.type_of.has_expr) w.append_string("<expr>: ");
			ty.type_of.base.dump(comp, w);
			w.append_string(")");
		case TYPEDEF:
			w.append_string(ty.type_def.name.lookup(comp));
			w.append_string(": ");
			ty.type_def.base.dump(comp, w);
		case ENUM:
			w.appendf("enum %s: ", ty.enum_ty.name.lookup(comp));
			if (ty.enum_ty.has_tag)
			{
				ty.enum_ty.tag.dump(comp, w);
			}
			else
			{
				w.append_string("<incomplete>");
			}
		default:
			self.unqualified().print(comp, w);
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
