// Narrow truncated arithmetic. C integer promotion turns `short` / `char`
// arithmetic into `trunc iN (op i32 (sext iN a), (sext iN b))`. The low N bits
// of + - * & | ^ ~ negation and `<<` by a constant depend only on the low N
// bits of their operands, so when every operation of such a tree has the
// truncation as its only (transitive) user, the tree computes the same value
// in iN directly:
//
//   i32 %x = sext i16 %a          i16 %m = mul i16 %b, i16 3
//   i32 %y = sext i16 %b    =>    i16 %t = add i16 %a, %m
//   i32 %m = mul nsw i32 %y, 3
//   i32 %s = add nsw i32 %x, %m
//   i16 %t = trunc i32 %s
//
// Leaves must be extensions from at most N bits (re-typed in place when
// narrower) or constants, so nothing new is placed in the body: the tree's
// operations are re-typed where they stand and the TRUNC itself becomes the
// root operation (the old root is left dead for dead_instruction_elim). `nsw`
// is dropped: the narrow operation may wrap. Besides removing the extensions,
// this is what lets loop_vectorize use 8 / 16-bit lanes.
module aro::backend::ir_opt;
import aro::backend::ir, aro::value_interner;
import std::collections::list;

const uint NARROW_MAX_DEPTH = 8;

struct NarrowContext
{
	ir::Ir* graph;
	DeclEditor* editor;
	<* Value operand references per instruction, over the body. *>
	uint[] uses;
	value_interner::InternerRef narrow;
	ushort width;
	<* Operations and re-typed extensions of the tree, operands before users. *>
	List{ir::Ref} nodes;
	<* Old roots and bypassed extensions: removed from the body when unused, so
	   later passes (loop_vectorize) never see their now mixed-width operands. *>
	List{ir::Ref} maybe_dead;
}

fn bool narrow_is_binary(ir::InstTag tag)
{
	switch (tag)
	{
		case ADD: case SUB: case MUL: case BIT_AND: case BIT_OR: case BIT_XOR: return true;
		default: return false;
	}
}

<* Whether `ref` can be recomputed in `ctx.width` bits; collects its nodes. `has_ext`: a
   leaf is an extension (a tree of constants is left to constant folding). *>
fn bool narrow_check(NarrowContext* ctx, ir::Ref ref, uint depth, bool* has_ext)
{
	if (depth > NARROW_MAX_DEPTH || (usz)ref >= (usz)ctx.editor.insts.len()) return false;
	ir::Inst inst = ctx.editor.insts.entries[(sz)ref];
	ir::Inst[] insts = ctx.editor.insts.array_view();
	switch (inst.tag)
	{
		case CONSTANT:
			ulong bits;
			return scalar_constant_bits(ctx.graph, insts, ref, &bits);
		case SEXT:
		case ZEXT:
			if ((usz)inst.data.ref >= insts.len) return false;
			ushort source_width;
			if (!const_prop_int_width(ctx.graph, insts[(sz)inst.data.ref].ty, &source_width)) return false;
			if (source_width == ctx.width) { *has_ext = true; return true; }
			// A narrower source: the extension itself is re-typed (sext i8 -> i16).
			if (source_width < ctx.width && ctx.uses[(sz)ref] == 1)
			{
				*has_ext = true;
				ctx.nodes.push(ref);
				return true;
			}
			return false;
		case BIT_NOT:
		case NEGATE:
			if (ctx.uses[(sz)ref] != 1 || !narrow_check(ctx, inst.data.ref, depth + 1, has_ext)) return false;
			ctx.nodes.push(ref);
			return true;
		case BIT_SHL:
			ulong count;
			if (ctx.uses[(sz)ref] != 1 || !scalar_constant_bits(ctx.graph, insts, inst.data.bin.rhs, &count) || count >= ctx.width) return false;
			if (!narrow_check(ctx, inst.data.bin.lhs, depth + 1, has_ext)) return false;
			ctx.nodes.push(ref);
			return true;
		default:
			if (!narrow_is_binary(inst.tag) || ctx.uses[(sz)ref] != 1) return false;
			if (!narrow_check(ctx, inst.data.bin.lhs, depth + 1, has_ext)) return false;
			if (inst.data.bin.lhs != inst.data.bin.rhs && !narrow_check(ctx, inst.data.bin.rhs, depth + 1, has_ext)) return false;
			ctx.nodes.push(ref);
			return true;
	}
}

<* The narrow form of operand `ref`: a constant's low bits, an extension's
   same-width source, or the (re-typed) node itself. *>
fn ir::Ref narrow_operand(NarrowContext* ctx, ir::Ref ref)
{
	ir::Inst inst = ctx.editor.insts.entries[(sz)ref];
	if (inst.tag == ir::InstTag.CONSTANT)
	{
		ulong bits;
		scalar_constant_bits(ctx.graph, ctx.editor.insts.array_view(), ref, &bits);
		return instcombine_int_constant(ctx.graph, ctx.editor, ctx.width, bits & const_prop_mask(ctx.width), ctx.narrow);
	}
	if ((inst.tag == ir::InstTag.SEXT || inst.tag == ir::InstTag.ZEXT) && ctx.editor.insts.entries[(sz)inst.data.ref].ty == ctx.narrow)
	{
		ctx.maybe_dead.push(ref);
		return inst.data.ref;
	}
	return ref;
}

<* Re-type node `ref` to the narrow type, its operands mapped by narrow_operand. *>
fn ir::Inst narrow_node(NarrowContext* ctx, ir::Ref ref)
{
	ir::Inst inst = ctx.editor.insts.entries[(sz)ref];
	switch (inst.tag)
	{
		case SEXT:
		case ZEXT:
			break;
		case BIT_NOT:
		case NEGATE:
			inst.data.ref = narrow_operand(ctx, inst.data.ref);
		case BIT_SHL:
			// The count keeps its type and value (< width, checked).
			inst.data.bin.lhs = narrow_operand(ctx, inst.data.bin.lhs);
		default:
			inst.data.bin.lhs = narrow_operand(ctx, inst.data.bin.lhs);
			inst.data.bin.rhs = narrow_operand(ctx, inst.data.bin.rhs);
	}
	inst.ty = ctx.narrow;
	inst.nsw = false;
	return inst;
}

fn bool narrow_body_removed(ir::Ref ref, void* context) => ((bool*)context)[(sz)ref];

<* Drop the `maybe_dead` instructions that lost every user, to a fixpoint (an
   old root's operands can be bypassed extensions). *>
fn void narrow_remove_dead(NarrowContext* ctx)
{
	DeclEditor* editor = ctx.editor;
	usz count = (usz)editor.insts.len();
	bool[] removed = alloc::new_array(tmem, bool, (sz)count);
	uint[] uses = alloc::new_array(tmem, uint, (sz)count);
	bool progress = true;
	while (progress)
	{
		progress = false;
		uses[..] = 0;
		foreach (ref : editor.body)
		{
			if ((usz)ref >= count || removed[(sz)ref]) continue;
			@each_value_operand(&editor.insts.entries[(sz)ref]; ir::Ref* slot)
			{
				if ((usz)*slot < count) uses[(sz)*slot]++;
			};
		}
		foreach (ref : ctx.maybe_dead)
		{
			if ((usz)ref >= count || removed[(sz)ref] || uses[(sz)ref] != 0) continue;
			removed[(sz)ref] = true;
			progress = true;
		}
	}
	editor.remove_body_where(&narrow_body_removed, removed.ptr);
}

fn bool narrow_truncated_arith(ir::Ir* graph, ir::Decl* decl, FunctionAnalyses* fa)
{
	if (decl.kind != ir::DeclKind.FUNCTION || !decl.body.len) return false;
	@pool()
	{
		DeclEditor editor;
		editor.begin(decl);
		NarrowContext ctx = { .graph = graph, .editor = &editor };
		ctx.uses = alloc::new_array(tmem, uint, (sz)editor.insts.len());
		ctx.nodes.init(tmem);
		ctx.maybe_dead.init(tmem);
		foreach (ref : editor.body)
		{
			if ((usz)ref >= (usz)editor.insts.len()) continue;
			@each_value_operand(&editor.insts.entries[(sz)ref]; ir::Ref* slot)
			{
				if ((usz)*slot < ctx.uses.len) ctx.uses[(sz)*slot]++;
			};
		}
		bool changed = false;
		usz original_len = (usz)editor.insts.len();
		foreach (ref : editor.body)
		{
			if ((usz)ref >= original_len) continue;
			ir::Inst trunc = editor.insts.entries[(sz)ref];
			if (trunc.tag != ir::InstTag.TRUNC || (usz)trunc.data.ref >= original_len) continue;
			ir::Ref root = trunc.data.ref;
			ir::InstTag root_tag = editor.insts.entries[(sz)root].tag;
			if (!narrow_is_binary(root_tag) && root_tag != ir::InstTag.BIT_NOT && root_tag != ir::InstTag.NEGATE &&
				root_tag != ir::InstTag.BIT_SHL) continue;
			ushort width;
			ushort wide;
			if (!const_prop_int_width(graph, trunc.ty, &width) || width < 8 ||
				!const_prop_int_width(graph, editor.insts.entries[(sz)root].ty, &wide) || wide > 64) continue;
			ctx.narrow = trunc.ty;
			ctx.width = width;
			ctx.nodes.clear();
			bool has_ext = false;
			if (!narrow_check(&ctx, root, 0, &has_ext) || !has_ext) continue;
			foreach (node : ctx.nodes)
			{
				ir::Inst narrowed = narrow_node(&ctx, node);
				if (node == root)
				{
					// The truncation becomes the root; the old root is now unused.
					editor.insts.entries[(sz)ref] = narrowed;
				}
				else
				{
					editor.insts.entries[(sz)node] = narrowed;
				}
			}
			ctx.maybe_dead.push(root);
			changed = true;
		}
		if (changed) narrow_remove_dead(&ctx);
		if (!changed)
		{
			editor.free();
			return false;
		}
		editor.commit();
		fa.mark_dirty();
		return true;
	};
}
