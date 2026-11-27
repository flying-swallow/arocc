// Soft-float legalization: x86_64 has no `__float128` arithmetic instructions,
// so every f128 operation becomes a call to the libgcc routine GCC itself uses
// (`__addtf3`, `__lttf2`, `__extenddftf2`, ...). f128 values themselves stay
// 128-bit XMM values that the lowering only moves. Runs on fresh CodeGen output,
// before the optimizer, at every -O level.
module aro::backend::ir_opt;
import aro::backend::ir, aro::value_interner, aro::primitive_value, std::collections::list;

fn bool is_f128(ir::Ir* graph, value_interner::InternerRef ty)
{
	primitive_value::PrimitiveValue key = graph.interner.get(ty);
	return key.tag == primitive_value::PrimitiveType.FLOAT_TY && key.ty_bits == 128;
}

fn uint type_bits(ir::Ir* graph, value_interner::InternerRef ty)
{
	if (ty == value_interner::REF_PTR) return 64;
	return graph.interner.get(ty).ty_bits;
}

fn bool is_f16(ir::Ir* graph, value_interner::InternerRef ty)
{
	primitive_value::PrimitiveValue key = graph.interner.get(ty);
	return key.tag == primitive_value::PrimitiveType.FLOAT_TY && key.ty_bits == 16;
}

<* Whether `inst` computes on (not just moves) a `_Float16` value. *>
fn bool uses_f16(ir::Ir* graph, ir::Decl* decl, ir::Inst inst)
{
	switch (inst.tag)
	{
		case FADD: case FSUB: case FMUL: case FDIV: case FNEG: case FABS:
		case SITOFP: case UITOFP: case FPTRUNC:
			return is_f16(graph, inst.ty);
		case FCMP_OEQ: case FCMP_UNE: case FCMP_OLT: case FCMP_OLE: case FCMP_OGT: case FCMP_OGE:
			return is_f16(graph, decl.instructions[(sz)inst.data.bin.lhs].ty);
		case FPEXT: case FPTOSI: case FPTOUI:
			return is_f16(graph, decl.instructions[(sz)inst.data.ref].ty);
		default:
			return false;
	}
}

<* f16 -> f32 (`__extendhfsf2`), placed before the current instruction. *>
fn ir::Ref extend_f16(DeclEditor* editor, ir::Decl* decl, ir::Ref value, List{ir::Ref}* body)
{
	ir::Ref[1] arg = { value };
	ir::Ref call = append_call(editor, decl, "__extendhfsf2", arg[..], value_interner::REF_F32, body);
	body.push(call);
	return call;
}

<* `_Float16` arithmetic is done in float, rounding back to half after each
   operation (GCC without AVX512-FP16 does the same through libgcc). *>
fn void? legalize_decl_f16(ir::Ir* graph, ir::Decl* decl)
{
	DeclEditor editor;
	editor.begin(decl);
	List{ir::Ref} body;
	body.init(decl.allocator);
	defer body.free();
	foreach (ref : decl.body)
	{
		ir::Inst inst = editor.insts[(sz)ref];
		if (!uses_f16(graph, decl, inst))
		{
			body.push(ref);
			continue;
		}
		switch (inst.tag)
		{
			case FADD: case FSUB: case FMUL: case FDIV:
				ir::Ref a = extend_f16(&editor, decl, inst.data.bin.lhs, &body);
				ir::Ref b = extend_f16(&editor, decl, inst.data.bin.rhs, &body);
				ir::Ref wide = editor.append({ .tag = inst.tag, .data.bin = { a, b }, .ty = value_interner::REF_F32 });
				body.push(wide);
				ir::Ref[1] arg = { wide };
				ir::Ref round = append_call(&editor, decl, "__truncsfhf2", arg[..], inst.ty, &body);
				editor.insts[(sz)ref] = editor.insts[(sz)round];
				editor.insts[(sz)round].tag = ARG; // unplaced tombstone
			case FNEG: case FABS:
				ir::Ref a = extend_f16(&editor, decl, inst.data.ref, &body);
				ir::Ref wide = editor.append({ .tag = inst.tag, .data.ref = a, .ty = value_interner::REF_F32 });
				body.push(wide);
				ir::Ref[1] arg = { wide };
				ir::Ref round = append_call(&editor, decl, "__truncsfhf2", arg[..], inst.ty, &body);
				editor.insts[(sz)ref] = editor.insts[(sz)round];
				editor.insts[(sz)round].tag = ARG;
			case FCMP_OEQ: case FCMP_UNE: case FCMP_OLT: case FCMP_OLE: case FCMP_OGT: case FCMP_OGE:
				ir::Ref a = extend_f16(&editor, decl, inst.data.bin.lhs, &body);
				ir::Ref b = extend_f16(&editor, decl, inst.data.bin.rhs, &body);
				editor.insts[(sz)ref].data.bin = { a, b };
			case FPEXT:
				if (inst.ty == value_interner::REF_F32)
				{
					// The extension itself is the call.
					ir::Ref[1] arg = { inst.data.ref };
					ir::Ref call = append_call(&editor, decl, "__extendhfsf2", arg[..], inst.ty, &body);
					editor.insts[(sz)ref] = editor.insts[(sz)call];
					editor.insts[(sz)call].tag = ARG;
				}
				else
				{
					editor.insts[(sz)ref].data.ref = extend_f16(&editor, decl, inst.data.ref, &body);
				}
			case FPTOSI: case FPTOUI:
				editor.insts[(sz)ref].data.ref = extend_f16(&editor, decl, inst.data.ref, &body);
			case SITOFP: case UITOFP:
				ir::Ref wide = editor.append({ .tag = inst.tag, .data.ref = inst.data.ref, .ty = value_interner::REF_F32 });
				body.push(wide);
				ir::Ref[1] arg = { wide };
				ir::Ref round = append_call(&editor, decl, "__truncsfhf2", arg[..], inst.ty, &body);
				editor.insts[(sz)ref] = editor.insts[(sz)round];
				editor.insts[(sz)round].tag = ARG;
			case FPTRUNC:
				String name;
				switch (type_bits(graph, editor.insts[(sz)inst.data.ref].ty))
				{
					case 32: name = "__truncsfhf2";
					case 64: name = "__truncdfhf2";
					case 80: name = "__truncxfhf2";
					default: name = "__trunctfhf2";
				}
				ir::Ref[1] arg = { inst.data.ref };
				ir::Ref call = append_call(&editor, decl, name, arg[..], inst.ty, &body);
				editor.insts[(sz)ref] = editor.insts[(sz)call];
				editor.insts[(sz)call].tag = ARG;
			default:
				unreachable();
		}
		body.push(ref);
	}
	editor.body.clear();
	editor.body.push_all(body.array_view());
	editor.commit();
}

<* Lower the f16 and f128 operations of every function to libgcc calls. *>
fn void? legalize_soft_float(ir::Ir* graph, ir::ErrorList* errors)
{
	foreach (&decl : graph.decls)
	{
		if (decl.kind != ir::DeclKind.FUNCTION || !decl.body.len) continue;
		foreach (ref : decl.body)
		{
			if (uses_f16(graph, decl, decl.instructions[(sz)ref]))
			{
				legalize_decl_f16(graph, decl)!;
				break;
			}
		}
	}
	foreach (&decl : graph.decls)
	{
		if (decl.kind != ir::DeclKind.FUNCTION || !decl.body.len) continue;
		bool found = false;
		String routine;
		foreach (ref : decl.body)
		{
			if (soft_float_routine(graph, decl, decl.instructions[(sz)ref], &routine)) { found = true; break; }
		}
		if (found) legalize_decl_soft_float(graph, decl, errors)!;
	}
}

<* The libgcc routine for `inst` when it operates on f128, else false. *>
fn bool soft_float_routine(ir::Ir* graph, ir::Decl* decl, ir::Inst inst, String* name)
{
	switch (inst.tag)
	{
		case FADD: case FSUB: case FMUL: case FDIV: case FNEG: case FABS:
			if (!is_f128(graph, inst.ty)) return false;
			switch (inst.tag)
			{
				case FADD: *name = "__addtf3";
				case FSUB: *name = "__subtf3";
				case FMUL: *name = "__multf3";
				case FDIV: *name = "__divtf3";
				case FNEG: *name = "__negtf2";
				default: *name = "fabsf128";
			}
			return true;
		case FCMP_OEQ: case FCMP_UNE: case FCMP_OLT: case FCMP_OLE: case FCMP_OGT: case FCMP_OGE:
			if (!is_f128(graph, decl.instructions[(sz)inst.data.bin.lhs].ty)) return false;
			switch (inst.tag)
			{
				case FCMP_OEQ: *name = "__eqtf2";
				case FCMP_UNE: *name = "__netf2";
				case FCMP_OLT: *name = "__lttf2";
				case FCMP_OLE: *name = "__letf2";
				case FCMP_OGT: *name = "__gttf2";
				default: *name = "__getf2";
			}
			return true;
		case FPEXT:
			if (!is_f128(graph, inst.ty)) return false;
			switch (type_bits(graph, decl.instructions[(sz)inst.data.ref].ty))
			{
				case 32: *name = "__extendsftf2";
				case 64: *name = "__extenddftf2";
				case 80: *name = "__extendxftf2";
				default: *name = "__extendhftf2";
			}
			return true;
		case FPTRUNC:
			if (!is_f128(graph, decl.instructions[(sz)inst.data.ref].ty)) return false;
			switch (type_bits(graph, inst.ty))
			{
				case 32: *name = "__trunctfsf2";
				case 64: *name = "__trunctfdf2";
				case 80: *name = "__trunctfxf2";
				default: *name = "__trunctfhf2";
			}
			return true;
		case SITOFP:
		case UITOFP:
			if (!is_f128(graph, inst.ty)) return false;
			bool wide = type_bits(graph, decl.instructions[(sz)inst.data.ref].ty) > 32;
			if (inst.tag == SITOFP) { *name = wide ? "__floatditf" : "__floatsitf"; } else { *name = wide ? "__floatunditf" : "__floatunsitf"; }
			return true;
		case FPTOSI:
		case FPTOUI:
			if (!is_f128(graph, decl.instructions[(sz)inst.data.ref].ty)) return false;
			bool wide = type_bits(graph, inst.ty) > 32;
			if (inst.tag == FPTOSI) { *name = wide ? "__fixtfdi" : "__fixtfsi"; } else { *name = wide ? "__fixunstfdi" : "__fixunstfsi"; }
			return true;
		default:
			return false;
	}
}

fn ir::Ref append_call(DeclEditor* editor, ir::Decl* decl, String name, ir::Ref[] args, value_interner::InternerRef ty,
	List{ir::Ref}* body)
{
	ir::Ref symbol = editor.append({ .tag = SYMBOL, .data.label = name.copy(&decl.arena), .ty = value_interner::REF_PTR });
	body.push(symbol);
	ir::Ref[] owned = alloc::new_array(&decl.arena, ir::Ref, args.len);
	owned[..] = args[..];
	bool[] stack_only = alloc::new_array(&decl.arena, bool, args.len);
	uint[] copy = alloc::new_array(&decl.arena, uint, args.len);
	for (usz i = 0; i < args.len; i++) { stack_only[i] = false; copy[i] = 0; }
	return editor.append({ .tag = CALL, .data.call = { .func = symbol, .args = owned, .stack_only = stack_only, .memory_copy_bytes = copy }, .ty = ty });
}

fn void? legalize_decl_soft_float(ir::Ir* graph, ir::Decl* decl, ir::ErrorList* errors)
{
	DeclEditor editor;
	editor.begin(decl);
	List{ir::Ref} body;
	body.init(decl.allocator);
	defer body.free();
	foreach (ref : decl.body)
	{
		ir::Inst inst = editor.insts[(sz)ref];
		String name;
		if (!soft_float_routine(graph, decl, inst, &name))
		{
			body.push(ref);
			continue;
		}
		ir::Ref symbol = editor.append({ .tag = SYMBOL, .data.label = name.copy(&decl.arena), .ty = value_interner::REF_PTR });
		body.push(symbol);
		ir::Ref[] args;
		switch (inst.tag)
		{
			case FADD: case FSUB: case FMUL: case FDIV:
				args = alloc::new_array(&decl.arena, ir::Ref, 2);
				args[0] = inst.data.bin.lhs;
				args[1] = inst.data.bin.rhs;
			case FCMP_OEQ: case FCMP_UNE: case FCMP_OLT: case FCMP_OLE: case FCMP_OGT: case FCMP_OGE:
				// `__xxtf2(a, b)` returns an int compared against zero.
				ir::Ref[2] operands = { inst.data.bin.lhs, inst.data.bin.rhs };
				body.pop()!!;
				ir::Ref result = append_call(&editor, decl, name, operands[..], value_interner::REF_I32, &body);
				body.push(result);
				ir::Ref zero = editor.add_constant(value_interner::REF_ZERO, value_interner::REF_I32);
				ir::InstTag compare;
				switch (inst.tag)
				{
					case FCMP_OEQ: compare = CMP_EQ;
					case FCMP_UNE: compare = CMP_NE;
					case FCMP_OLT: compare = CMP_SLT;
					case FCMP_OLE: compare = CMP_SLTE;
					case FCMP_OGT: compare = CMP_SGT;
					default: compare = CMP_SGTE;
				}
				editor.insts[(sz)ref] = { .tag = compare, .data.bin = { result, zero }, .ty = value_interner::REF_I1 };
				body.push(ref);
				continue;
			case SITOFP:
			case UITOFP:
				ir::Ref source = inst.data.ref;
				uint bits = type_bits(graph, editor.insts[(sz)source].ty);
				if (bits > 64)
				{
					errors.put(decl.name, "TODO: 128-bit integer to __float128 conversion");
					return ir::LOWER_FAIL~;
				}
				if (bits != 32 && bits != 64)
				{
					// Widen narrow integers to the routine's argument type.
					source = editor.append({ .tag = inst.tag == SITOFP ? SEXT : ZEXT, .data.ref = source,
						.ty = bits < 32 ? value_interner::REF_I32 : value_interner::REF_I64 });
					body.push(source);
				}
				args = alloc::new_array(&decl.arena, ir::Ref, 1);
				args[0] = source;
			case FPTOSI:
			case FPTOUI:
				uint bits = type_bits(graph, inst.ty);
				if (bits != 32 && bits != 64)
				{
					// Convert at 32 bits, then narrow (bool/char/short targets).
					ir::Ref[1] operand = { inst.data.ref };
					body.pop()!!;
					ir::Ref wide = append_call(&editor, decl, name, operand[..], value_interner::REF_I32, &body);
					body.push(wide);
					editor.insts[(sz)ref] = { .tag = TRUNC, .data.ref = wide, .ty = inst.ty };
					body.push(ref);
					continue;
				}
				args = alloc::new_array(&decl.arena, ir::Ref, 1);
				args[0] = inst.data.ref;
			default:
				args = alloc::new_array(&decl.arena, ir::Ref, 1);
				args[0] = inst.data.ref;
		}
		bool[] stack_only = alloc::new_array(&decl.arena, bool, args.len);
		uint[] copy = alloc::new_array(&decl.arena, uint, args.len);
		for (usz i = 0; i < args.len; i++) { stack_only[i] = false; copy[i] = 0; }
		editor.insts[(sz)ref] = { .tag = CALL, .data.call = { .func = symbol, .args = args, .stack_only = stack_only, .memory_copy_bytes = copy }, .ty = inst.ty };
		body.push(ref);
	}
	editor.body.clear();
	editor.body.push_all(body.array_view());
	editor.commit();
}
