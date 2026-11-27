// Loop strength reduction for addresses (LLVM LoopStrengthReduce, reduced to
// the address case). An in-loop `add ptr base, X` with `base` loop-invariant and
// `X` an affine i64 function of a basic induction variable, `X = s*iv + b`,
// becomes a pointer PHI stepped by the invariant `s*step` per iteration. i64
// and pointer arithmetic are both modulo 2^64, so the rewrite is exact with no
// overflow reasoning; the C `int` indices reach this form through
// `indvar_widen`, which is where `nsw` matters.
module aro::backend::ir_opt;
import aro::backend::ir, aro::value_interner;
import std::collections::list;

const uint LSR_MAX_DEPTH = 8;
const uint LSR_MAX_PER_LOOP = 8;

<* Per-iteration coefficient `c * r` of an affine expression (`r == NONE` means just `c`). *>
struct LsrCoeff
{
	long c;
	ir::Ref r;
}

struct LsrInsert
{
	sz before;
	ir::Ref inst;
}

struct LsrContext
{
	ir::Ir* graph;
	ir::Decl* decl;
	DeclEditor* editor;
	Cfg* cfg;
	Loop* loop;
	usz original_len;
	BasicIndVar* iv;
	<* Set when `X` has an invariant non-constant leaf (or coefficient): a plain
	   `iv * scale` index is already free in an x86 address. *>
	bool has_invariant_leaf;
	list::List{LsrInsert} inserts;
}

fn bool lsr_invariant(LsrContext* ctx, ir::Ref ref)
{
	ir::InstTag tag = ctx.editor.insts.entries[(sz)ref].tag;
	if (tag == ir::InstTag.CONSTANT || tag == ir::InstTag.ARG || tag == ir::InstTag.SYMBOL) return true;
	if ((usz)ref >= ctx.original_len) return false;
	uint home = ctx.cfg.block_of_ref[(sz)ref];
	if (home == NONE_BLOCK) return false;
	return !loop_body_contains(ctx.loop, home);
}

fn bool lsr_constant(LsrContext* ctx, ir::Ref ref, long* value)
{
	ulong bits;
	if (!scalar_constant_bits(ctx.graph, ctx.editor.insts.array_view(), ref, &bits)) return false;
	*value = (long)bits;
	return true;
}

<* The per-unit-IV coefficient of i64 `ref`, or false when `ref` is not affine in `ctx.iv`. *>
fn bool lsr_affine(LsrContext* ctx, ir::Ref ref, LsrCoeff* out, uint depth)
{
	if ((usz)ref >= (usz)ctx.editor.insts.len() || ctx.editor.insts.entries[(sz)ref].ty != value_interner::REF_I64) return false;
	if (ref == ctx.iv.phi)
	{
		*out = { .c = 1, .r = ir::NONE };
		return true;
	}
	if (lsr_invariant(ctx, ref))
	{
		if (ctx.editor.insts.entries[(sz)ref].tag != ir::InstTag.CONSTANT) ctx.has_invariant_leaf = true;
		*out = { .c = 0, .r = ir::NONE };
		return true;
	}
	if (depth >= LSR_MAX_DEPTH) return false;
	ir::Inst inst = ctx.editor.insts.entries[(sz)ref];
	switch (inst.tag)
	{
		case ADD:
		case SUB:
			LsrCoeff a, b;
			if (!lsr_affine(ctx, inst.data.bin.lhs, &a, depth + 1) || !lsr_affine(ctx, inst.data.bin.rhs, &b, depth + 1)) return false;
			if (inst.tag == ir::InstTag.SUB) b.c = 0 - b.c;
			if (a.c == 0) { *out = b; return true; }
			if (b.c == 0) { *out = a; return true; }
			if (a.r != b.r) return false;
			*out = { .c = a.c + b.c, .r = a.r };
			return true;
		case NEGATE:
			LsrCoeff a;
			if (!lsr_affine(ctx, inst.data.ref, &a, depth + 1)) return false;
			*out = { .c = 0 - a.c, .r = a.r };
			return true;
		case MUL:
		case BIT_SHL:
			// One factor must be the IV-free invariant scale.
			ir::Ref lhs = inst.data.bin.lhs;
			ir::Ref rhs = inst.data.bin.rhs;
			long k;
			if (inst.tag == ir::InstTag.BIT_SHL)
			{
				if (!lsr_constant(ctx, rhs, &k) || k < 0 || k > 62) return false;
				k = (long)1 << k;
				LsrCoeff a;
				if (!lsr_affine(ctx, lhs, &a, depth + 1)) return false;
				*out = { .c = a.c * k, .r = a.r };
				return true;
			}
			if (lsr_invariant(ctx, lhs) && !lsr_invariant(ctx, rhs)) { ir::Ref t = lhs; lhs = rhs; rhs = t; }
			if (!lsr_invariant(ctx, rhs)) return false;
			LsrCoeff a;
			if (!lsr_affine(ctx, lhs, &a, depth + 1)) return false;
			if (a.c == 0) { *out = a; return true; }
			if (lsr_constant(ctx, rhs, &k))
			{
				*out = { .c = a.c * k, .r = a.r };
				return true;
			}
			if (a.r != ir::NONE) return false;
			ctx.has_invariant_leaf = true;
			*out = { .c = a.c, .r = rhs };
			return true;
		default:
			return false;
	}
}

fn void lsr_insert_before(LsrContext* ctx, sz before, ir::Ref inst)
{
	ctx.inserts.push({ .before = before, .inst = inst });
}

<* Clone the in-loop part of `ref` with the IV PHI replaced by `init`, appending the
   new instructions before body position `before` (in the preheader). *>
fn ir::Ref lsr_clone_at_init(LsrContext* ctx, ir::Ref ref, ir::Ref init, sz before)
{
	if (ref == ctx.iv.phi) return init;
	if (lsr_invariant(ctx, ref)) return ref;
	ir::Inst inst = ctx.editor.insts.entries[(sz)ref];
	ir::Inst copy = { .tag = inst.tag, .ty = inst.ty };
	if (inst.tag == ir::InstTag.NEGATE)
	{
		copy.data.ref = lsr_clone_at_init(ctx, inst.data.ref, init, before);
	}
	else
	{
		ir::Ref lhs = lsr_clone_at_init(ctx, inst.data.bin.lhs, init, before);
		ir::Ref rhs = lsr_clone_at_init(ctx, inst.data.bin.rhs, init, before);
		copy.data.bin = { lhs, rhs };
	}
	ir::Ref cloned = ctx.editor.append(copy);
	lsr_insert_before(ctx, before, cloned);
	return cloned;
}

<* `X` is just the IV times a constant addressing scale, plus constants. *>
fn bool lsr_trivially_addressable(LsrContext* ctx, LsrCoeff coeff)
{
	if (ctx.has_invariant_leaf || coeff.r != ir::NONE) return false;
	return coeff.c == 1 || coeff.c == 2 || coeff.c == 4 || coeff.c == 8;
}

fn bool loop_strength_reduce(ir::Ir* graph, ir::Decl* decl, FunctionAnalyses* cached = null)
{
	@pool()
	{
		FunctionAnalyses owned_analyses;
		FunctionAnalyses* analyses = function_analyses(cached, &owned_analyses, decl);
		defer owned_analyses.free();
		if (decl.kind != ir::DeclKind.FUNCTION || !decl.body.len) return false;
		foreach (ref : decl.body)
		{
			if ((usz)ref >= (usz)decl.instructions.len) continue;
			ir::InstTag tag = decl.instructions[(sz)ref].tag;
			if (tag == ir::InstTag.LABEL_ADDR || tag == ir::InstTag.JMP_VAL) return false;
		}
		bool preheaders_changed = ensure_preheaders(decl, analyses);
		Cfg* cfg = analyses.get_cfg();
		if (!cfg.blocks.len) return preheaders_changed;
		LoopInfo* loops = analyses.get_loops();
		if (!loops.loops.len()) return preheaders_changed;
		DeclEditor editor;
		editor.begin(decl);
		LsrContext ctx = { .graph = graph, .decl = decl, .editor = &editor, .cfg = cfg, .original_len = decl.instructions.len };
		ctx.inserts.init(mem);
		defer ctx.inserts.free();
		bool changed = false;
		foreach (loop_index, &loop : loops.loops)
		{
			if (loop.header == 0 || loop.latches.len() != 1) continue;
			uint preheader = loop_existing_preheader(decl, cfg, loops, (uint)loop_index);
			if (preheader == NONE_BLOCK) continue;
			uint latch = loop.latches.entries[0];
			list::List{BasicIndVar} ivs;
			ivs.init(mem);
			defer ivs.free();
			loop_basic_ivs(graph, decl, cfg, loops, (uint)loop_index, preheader, latch, &ivs);
			if (!ivs.len()) continue;
			ctx.loop = loop;
			sz pre_pos = block_terminator_position(decl, &cfg.blocks[(sz)preheader]);
			sz latch_pos = block_terminator_position(decl, &cfg.blocks[(sz)latch]);
			sz header_pos = cfg.blocks[(sz)loop.header].start + 1;
			uint rewritten = 0;
			foreach (block_index : loop.blocks)
			{
				if (rewritten >= LSR_MAX_PER_LOOP) break;
				if (loops.innermost_of_block[(sz)block_index] != (uint)loop_index) continue;
				CfgBlock* block = &cfg.blocks[(sz)block_index];
				for (sz pos = block.start + 1; pos < block.end && rewritten < LSR_MAX_PER_LOOP; pos++)
				{
					ir::Ref ref = decl.body[pos];
					ir::Inst cand = editor.insts.entries[(sz)ref];
					if (cand.tag != ir::InstTag.ADD || cand.ty != value_interner::REF_PTR) continue;
					ir::Ref base = cand.data.bin.lhs;
					ir::Ref index = cand.data.bin.rhs;
					if (!lsr_invariant(&ctx, base)) continue;
					foreach (&iv : ivs)
					{
						if (iv.ty != value_interner::REF_I64) continue;
						ctx.iv = iv;
						ctx.has_invariant_leaf = false;
						LsrCoeff coeff;
						if (!lsr_affine(&ctx, index, &coeff, 0) || coeff.c == 0) continue;
						if (lsr_trivially_addressable(&ctx, coeff)) continue;
						long step = (long)iv.step_bits;
						// Stride s*step, computed in the preheader.
						ir::Ref stride;
						ir::Ref scale = scalar_constant(graph, &editor, 64, (ulong)(coeff.c * step), value_interner::REF_I64);
						if (coeff.r == ir::NONE)
						{
							stride = scale;
						}
						else
						{
							stride = editor.append({ .tag = ir::InstTag.MUL, .data.bin = { coeff.r, scale }, .ty = value_interner::REF_I64 });
							lsr_insert_before(&ctx, pre_pos, stride);
						}
						ir::Ref start_index = lsr_clone_at_init(&ctx, index, iv.init, pre_pos);
						ir::Ref start = editor.append({ .tag = ir::InstTag.ADD, .data.bin = { base, start_index }, .ty = value_interner::REF_PTR });
						lsr_insert_before(&ctx, pre_pos, start);
						ir::PhiInput[] inputs = alloc::new_array(&decl.arena, ir::PhiInput, 2);
						ir::Ref phi = editor.append({ .tag = ir::InstTag.PHI, .data.phi = inputs, .ty = value_interner::REF_PTR });
						lsr_insert_before(&ctx, header_pos, phi);
						ir::Ref next = editor.append({ .tag = ir::InstTag.ADD, .data.bin = { phi, stride }, .ty = value_interner::REF_PTR });
						lsr_insert_before(&ctx, latch_pos, next);
						ir::PhiInput[] placed = editor.insts.entries[(sz)phi].data.phi;
						placed[0] = { .label = cfg.blocks[(sz)preheader].label, .value = start };
						placed[1] = { .label = cfg.blocks[(sz)latch].label, .value = next };
						editor_replace_all_uses(&editor, ref, phi);
						rewritten++;
						changed = true;
						break;
					}
				}
			}
		}
		if (!changed) { editor.free(); return preheaders_changed; }
		// Rebuild the body with each insert before its position, in creation order.
		sz old_len = editor.body.len();
		ir::Ref[] old_body = alloc::new_array(tmem, ir::Ref, old_len);
		for (sz i = 0; i < old_len; i++) old_body[i] = editor.body.entries[i];
		uint[] first = alloc::new_array(tmem, uint, old_len + 2);
		first[..] = 0;
		foreach (insert : ctx.inserts) first[insert.before + 1]++;
		for (sz i = 0; i <= old_len; i++) first[i + 1] += first[i];
		uint[] fill = alloc::new_array(tmem, uint, old_len + 1);
		for (sz i = 0; i <= old_len; i++) fill[i] = first[i];
		ir::Ref[] ordered = alloc::new_array(tmem, ir::Ref, ctx.inserts.len());
		foreach (insert : ctx.inserts) ordered[(sz)fill[insert.before]++] = insert.inst;
		editor.body.clear();
		for (sz pos = 0; pos <= old_len; pos++)
		{
			// PHIs first: a header insert position may also receive non-PHI code.
			for (uint k = first[pos]; k < first[pos + 1]; k++)
			{
				if (editor.insts.entries[(sz)ordered[(sz)k]].tag == ir::InstTag.PHI) editor.body.push(ordered[(sz)k]);
			}
			for (uint k = first[pos]; k < first[pos + 1]; k++)
			{
				if (editor.insts.entries[(sz)ordered[(sz)k]].tag != ir::InstTag.PHI) editor.body.push(ordered[(sz)k]);
			}
			if (pos < old_len) editor.body.push(old_body[pos]);
		}
		editor.commit();
		return true;
	};
}

// ---- Linear function test replacement ----
//
// After strength reduction the i64 IV often only feeds its own update and the
// loop's exit compare. For a top-tested `iv < bound` (step +1) the loop runs
// `cnt = max(bound - init, 0)` iterations, so `iv < bound` at iteration t is
// `t < cnt`, which is `P != start + cnt * C` for a pointer IV `P` stepping by C.
// That makes the integer IV dead. Equality needs t*C distinct for t <= cnt mod
// 2^64: init and bound are limited to the int32 range (cnt < 2^32) and |C| < 2^31.

<* `ref` is a constant in the int32 range or the sign extension of a value at most 32 bits wide. *>
fn bool lftr_int32_range(ir::Ir* graph, ir::Inst[] insts, ir::Ref ref)
{
	ulong bits;
	if (scalar_constant_bits(graph, insts, ref, &bits))
	{
		long value = (long)bits;
		return value >= int::min && value <= int::max;
	}
	ir::Inst inst = insts[(sz)ref];
	if (inst.tag != ir::InstTag.SEXT || (usz)inst.data.ref >= (usz)insts.len) return false;
	ushort width;
	return const_prop_int_width(graph, insts[(sz)inst.data.ref].ty, &width) && width <= 32;
}

<* A header pointer PHI `[start, preheader], [P + C, latch]` with constant 0 < |C| < 2^31. *>
fn bool lftr_pointer_iv(ir::Ir* graph, ir::Decl* decl, Cfg* cfg, uint preheader, uint latch, ir::Ref phi_ref,
	ir::Ref* start, long* stride)
{
	ir::Inst phi = decl.instructions[(sz)phi_ref];
	if (phi.tag != ir::InstTag.PHI || phi.ty != value_interner::REF_PTR || phi.data.phi.len != 2) return false;
	ir::Ref init = ir::NONE;
	ir::Ref next = ir::NONE;
	foreach (input : phi.data.phi)
	{
		if (input.label == cfg.blocks[(sz)preheader].label)
		{
			init = input.value;
		}
		else if (input.label == cfg.blocks[(sz)latch].label)
		{
			next = input.value;
		}
	}
	if (init == ir::NONE || next == ir::NONE || (usz)next >= (usz)decl.instructions.len) return false;
	ir::Inst update = decl.instructions[(sz)next];
	if (update.tag != ir::InstTag.ADD || update.ty != value_interner::REF_PTR || update.data.bin.lhs != phi_ref) return false;
	ulong bits;
	if (!scalar_constant_bits(graph, decl.instructions, update.data.bin.rhs, &bits)) return false;
	long c = (long)bits;
	if (c == 0 || c <= -(1L << 31) || c >= (1L << 31)) return false;
	*start = init;
	*stride = c;
	return true;
}

fn bool linear_function_test_replace(ir::Ir* graph, ir::Decl* decl, FunctionAnalyses* cached = null)
{
	@pool()
	{
		FunctionAnalyses owned_analyses;
		FunctionAnalyses* analyses = function_analyses(cached, &owned_analyses, decl);
		defer owned_analyses.free();
		if (decl.kind != ir::DeclKind.FUNCTION || !decl.body.len) return false;
		foreach (ref : decl.body)
		{
			if ((usz)ref >= (usz)decl.instructions.len) continue;
			ir::InstTag tag = decl.instructions[(sz)ref].tag;
			if (tag == ir::InstTag.LABEL_ADDR || tag == ir::InstTag.JMP_VAL) return false;
		}
		Cfg* cfg = analyses.get_cfg();
		if (!cfg.blocks.len) return false;
		LoopInfo* loops = analyses.get_loops();
		if (!loops.loops.len()) return false;
		Uses* uses = analyses.get_uses();
		DeclEditor editor;
		editor.begin(decl);
		usz original_len = decl.instructions.len;
		bool[] drop = alloc::new_array(tmem, bool, (sz)original_len);
		drop[..] = false;
		list::List{LsrInsert} inserts;
		inserts.init(mem);
		defer inserts.free();
		bool changed = false;
		foreach (loop_index, &loop : loops.loops)
		{
			if (loop.header == 0 || loop.latches.len() != 1) continue;
			uint preheader = loop_existing_preheader(decl, cfg, loops, (uint)loop_index);
			if (preheader == NONE_BLOCK) continue;
			uint latch = loop.latches.entries[0];
			CfgBlock* header = &cfg.blocks[(sz)loop.header];
			sz term_pos = block_terminator_position(decl, header);
			if (term_pos >= header.end) continue;
			ir::Inst branch = decl.instructions[(sz)decl.body[term_pos]];
			if (branch.tag != ir::InstTag.BRANCH) continue;
			// Continue on true, exit on false: the compare is false exactly once, at t = cnt.
			uint then_block = indvar_block_for_label(cfg, branch.data.branch.then_label);
			uint else_block = indvar_block_for_label(cfg, branch.data.branch.else_label);
			if (then_block == NONE_BLOCK || else_block == NONE_BLOCK ||
				!loop_body_contains(loop, then_block) || loop_body_contains(loop, else_block)) continue;
			ir::Ref cmp_ref = branch.data.branch.cond;
			if ((usz)cmp_ref >= original_len || uses.of(cmp_ref).len != 1 ||
				cfg.block_of_ref[(sz)cmp_ref] != loop.header) continue;
			ir::Inst cmp = decl.instructions[(sz)cmp_ref];
			ir::Ref iv_side;
			ir::Ref bound;
			bool inclusive;
			switch (cmp.tag)
			{
				case CMP_SLT: iv_side = cmp.data.bin.lhs; bound = cmp.data.bin.rhs; inclusive = false;
				case CMP_SLTE: iv_side = cmp.data.bin.lhs; bound = cmp.data.bin.rhs; inclusive = true;
				case CMP_SGT: iv_side = cmp.data.bin.rhs; bound = cmp.data.bin.lhs; inclusive = false;
				case CMP_SGTE: iv_side = cmp.data.bin.rhs; bound = cmp.data.bin.lhs; inclusive = true;
				default: continue;
			}
			if ((usz)bound >= original_len || (usz)iv_side >= original_len) continue;
			if (decl.instructions[(sz)bound].ty != value_interner::REF_I64) continue;
			uint bound_home = cfg.block_of_ref[(sz)bound];
			ir::InstTag bound_tag = decl.instructions[(sz)bound].tag;
			if (bound_tag != ir::InstTag.CONSTANT && bound_tag != ir::InstTag.ARG &&
				(bound_home == NONE_BLOCK || loop_body_contains(loop, bound_home))) continue;
			list::List{BasicIndVar} ivs;
			ivs.init(mem);
			defer ivs.free();
			loop_basic_ivs(graph, decl, cfg, loops, (uint)loop_index, preheader, latch, &ivs);
			BasicIndVar* iv = null;
			foreach (&candidate : ivs) if (candidate.phi == iv_side) { iv = candidate; break; }
			if (!iv || iv.ty != value_interner::REF_I64 || iv.step_bits != 1) continue;
			// The IV must die: only its update and this compare read it.
			if (uses.of(iv.phi).len != 2 || uses.of(iv.next).len != 1) continue;
			if (!lftr_int32_range(graph, decl.instructions, iv.init) || !lftr_int32_range(graph, decl.instructions, bound)) continue;
			ir::Ref start = ir::NONE;
			ir::Ref pointer = ir::NONE;
			long stride;
			for (sz pos = header.start + 1; pos < header.end; pos++)
			{
				ir::Ref ref = decl.body[pos];
				if (decl.instructions[(sz)ref].tag != ir::InstTag.PHI) break;
				if (lftr_pointer_iv(graph, decl, cfg, preheader, latch, ref, &start, &stride)) { pointer = ref; break; }
			}
			if (pointer == ir::NONE) continue;
			// Preheader: cnt = max(bound (+1) - init, 0); end = start + cnt * stride.
			sz pre_pos = block_terminator_position(decl, &cfg.blocks[(sz)preheader]);
			ir::Ref end;
			ulong init_bits, bound_bits;
			if (scalar_constant_bits(graph, decl.instructions, iv.init, &init_bits) &&
				scalar_constant_bits(graph, decl.instructions, bound, &bound_bits))
			{
				// Both in the int32 range, so none of this overflows.
				long count = (long)bound_bits + (inclusive ? 1 : 0) - (long)init_bits;
				if (count < 0) count = 0;
				ir::Ref offset = scalar_constant(graph, &editor, 64, (ulong)(count * stride), value_interner::REF_I64);
				end = editor.append({ .tag = ir::InstTag.ADD, .data.bin = { start, offset }, .ty = value_interner::REF_PTR });
				inserts.push({ .before = pre_pos, .inst = end });
			}
			else
			{
				ir::Ref limit = bound;
				if (inclusive)
				{
					ir::Ref one = scalar_constant(graph, &editor, 64, 1, value_interner::REF_I64);
					limit = editor.append({ .tag = ir::InstTag.ADD, .data.bin = { bound, one }, .ty = value_interner::REF_I64 });
					inserts.push({ .before = pre_pos, .inst = limit });
				}
				ir::Ref zero = scalar_constant(graph, &editor, 64, 0, value_interner::REF_I64);
				ir::Ref diff = editor.append({ .tag = ir::InstTag.SUB, .data.bin = { limit, iv.init }, .ty = value_interner::REF_I64 });
				ir::Ref negative = editor.append({ .tag = ir::InstTag.CMP_SLT, .data.bin = { diff, zero }, .ty = value_interner::REF_I1 });
				ir::Ref count = editor.append({ .tag = ir::InstTag.SELECT, .data.branch = { negative, zero, diff }, .ty = value_interner::REF_I64 });
				ir::Ref scale = scalar_constant(graph, &editor, 64, (ulong)stride, value_interner::REF_I64);
				ir::Ref offset = editor.append({ .tag = ir::InstTag.MUL, .data.bin = { count, scale }, .ty = value_interner::REF_I64 });
				end = editor.append({ .tag = ir::InstTag.ADD, .data.bin = { start, offset }, .ty = value_interner::REF_PTR });
				foreach (ref : (ir::Ref[]){ diff, negative, count, offset, end }) inserts.push({ .before = pre_pos, .inst = ref });
			}
			editor.insts.entries[(sz)cmp_ref] = { .tag = ir::InstTag.CMP_NE, .data.bin = { pointer, end }, .ty = value_interner::REF_I1 };
			drop[(sz)iv.phi] = true;
			drop[(sz)iv.next] = true;
			changed = true;
		}
		if (!changed) { editor.free(); return false; }
		sz old_len = editor.body.len();
		ir::Ref[] old_body = alloc::new_array(tmem, ir::Ref, old_len);
		for (sz i = 0; i < old_len; i++) old_body[i] = editor.body.entries[i];
		editor.body.clear();
		for (sz pos = 0; pos < old_len; pos++)
		{
			foreach (insert : inserts) if (insert.before == pos) editor.body.push(insert.inst);
			ir::Ref ref = old_body[pos];
			if ((usz)ref < original_len && drop[(sz)ref]) continue;
			editor.body.push(ref);
		}
		editor.commit();
		return true;
	};
}
