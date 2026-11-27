// Sign-extension elimination for loop index arithmetic (LLVM IndVarSimplify's
// widenIV, reduced). C `int` indices reach addresses as `sext i64 (op nsw i32)`;
// because `nsw` rules out wrapping, `sext (a op b) == (sext a) op (sext b)`, so
// the extension can move to the leaves. A loop-invariant leaf is extended once
// next to its definition (outside the loop); a basic induction variable whose
// update is `nsw` gets an i64 twin `phi64 == sext phi32`, so no per-iteration
// extension remains. Loop compares on the narrow IV move to the twin as well,
// which usually leaves the narrow IV dead.
module aro::backend::ir_opt;
import aro::backend::ir, aro::value_interner;
import std::collections::list;

<* Narrow-to-wide recursion bound for one extension root. *>
const uint WIDEN_MAX_DEPTH = 8;

struct WidenIv
{
	BasicIndVar iv;
	uint loop_index;
	uint preheader;
	uint latch;
	ir::Ref wide_phi;
	ir::Ref wide_next;
}

struct WidenInsert
{
	ir::Ref anchor;
	ir::Ref inst;
}

struct WidenContext
{
	ir::Ir* graph;
	ir::Decl* decl;
	DeclEditor* editor;
	Cfg* cfg;
	LoopInfo* loops;
	usz original_len;
	<* Original ref -> its i64 form (NONE until made). *>
	ir::Ref[] wide;
	<* Original ref -> index into `ivs` for a basic IV PHI or next value, else NONE. *>
	uint[] iv_of;
	list::List{WidenIv} ivs;
	list::List{WidenInsert} inserts;
}

<* Side-effect-free integer ops this pass can orphan. *>
fn bool widen_sweepable(ir::InstTag tag)
=> tag == ir::InstTag.ADD || tag == ir::InstTag.SUB || tag == ir::InstTag.MUL || tag == ir::InstTag.SEXT;

fn bool widen_is_iv_compare(ir::InstTag tag)
=> tag == ir::InstTag.CMP_EQ || tag == ir::InstTag.CMP_NE ||
tag == ir::InstTag.CMP_SLT || tag == ir::InstTag.CMP_SLTE ||
tag == ir::InstTag.CMP_SGT || tag == ir::InstTag.CMP_SGTE;

<* `ref` is computed outside `loop` (or is not placed at all). *>
fn bool widen_invariant(WidenContext* ctx, ir::Ref ref, Loop* loop)
{
	ir::InstTag tag = ctx.editor.insts.entries[(sz)ref].tag;
	if (tag == ir::InstTag.CONSTANT || tag == ir::InstTag.ARG || tag == ir::InstTag.SYMBOL) return true;
	uint home = ctx.cfg.block_of_ref[(sz)ref];
	if (home == NONE_BLOCK) return false;
	return !loop_body_contains(loop, home);
}

fn bool widen_narrow_int(WidenContext* ctx, ir::Ref ref, value_interner::InternerRef narrow)
{
	if ((usz)ref >= ctx.original_len) return false;
	return ctx.editor.insts.entries[(sz)ref].ty == narrow;
}

<* Whether widening `ref` for a root in `loop` removes work: every leaf the
   rewrite would extend is a constant, an induction variable, or loop-invariant
   (extended once outside the loop). *>
fn bool widen_profitable(WidenContext* ctx, ir::Ref ref, value_interner::InternerRef narrow, Loop* loop, uint depth)
{
	if (!widen_narrow_int(ctx, ref, narrow)) return false;
	if (ctx.wide[(sz)ref] != ir::NONE || ctx.iv_of[(sz)ref] != NONE_BLOCK) return true;
	if (widen_invariant(ctx, ref, loop)) return true;
	ir::Inst inst = ctx.editor.insts.entries[(sz)ref];
	if (!inst.nsw || !inst.tag.allows_nsw() || depth >= WIDEN_MAX_DEPTH) return false;
	return widen_profitable(ctx, inst.data.bin.lhs, narrow, loop, depth + 1) &&
		widen_profitable(ctx, inst.data.bin.rhs, narrow, loop, depth + 1);
}

fn void widen_place_after(WidenContext* ctx, ir::Ref anchor, ir::Ref inst)
{
	ctx.inserts.push({ .anchor = anchor, .inst = inst });
}

<* Where an extension of `ref` goes: after its definition, after the PHI group
   for a PHI, after the entry label for an ARG. *>
fn ir::Ref widen_anchor(WidenContext* ctx, ir::Ref ref)
{
	ir::Inst inst = ctx.editor.insts.entries[(sz)ref];
	if (inst.tag == ir::InstTag.ARG) return ctx.cfg.blocks[0].label;
	if (inst.tag != ir::InstTag.PHI) return ref;
	CfgBlock* block = &ctx.cfg.blocks[(sz)ctx.cfg.block_of_ref[(sz)ref]];
	ir::Ref last = ref;
	for (sz pos = block.start + 1; pos < block.end; pos++)
	{
		ir::Ref placed = ctx.decl.body[pos];
		if (ctx.decl.instructions[(sz)placed].tag != ir::InstTag.PHI) break;
		last = placed;
	}
	return last;
}

<* Make the i64 twin of basic IV `index`: `phi64 = [sext init, preheader], [next64, latch]`. *>
fn void widen_make_iv(WidenContext* ctx, uint index)
{
	WidenIv* entry = &ctx.ivs.entries[(sz)index];
	if (entry.wide_phi != ir::NONE) return;
	Loop* loop = &ctx.loops.loops.entries[(sz)entry.loop_index];
	ir::PhiInput[] inputs = alloc::new_array(&ctx.decl.arena, ir::PhiInput, 2);
	ir::Ref wide_phi = ctx.editor.append({ .tag = ir::InstTag.PHI, .data.phi = inputs, .ty = value_interner::REF_I64 });
	long step = const_prop_signed(entry.iv.step_bits, entry.iv.width);
	ir::Ref step_ref = scalar_constant(ctx.graph, ctx.editor, 64, (ulong)step, value_interner::REF_I64);
	ir::Ref wide_next = ctx.editor.append({ .tag = ir::InstTag.ADD, .nsw = true,
		.data.bin = { wide_phi, step_ref }, .ty = value_interner::REF_I64 });
	entry = &ctx.ivs.entries[(sz)index];
	entry.wide_phi = wide_phi;
	entry.wide_next = wide_next;
	ctx.wide[(sz)entry.iv.phi] = wide_phi;
	ctx.wide[(sz)entry.iv.next] = wide_next;
	widen_place_after(ctx, ctx.cfg.blocks[(sz)loop.header].label, wide_phi);
	widen_place_after(ctx, entry.iv.next, wide_next);
	ir::Ref init = widen_value(ctx, entry.iv.init, entry.iv.ty, 0);
	entry = &ctx.ivs.entries[(sz)index];
	// `.phi` is a slice into the decl arena, shared by the editor's copy.
	ir::PhiInput[] wide_inputs = ctx.editor.insts.entries[(sz)wide_phi].data.phi;
	wide_inputs[0] = { .label = ctx.cfg.blocks[(sz)entry.preheader].label, .value = init };
	wide_inputs[1] = { .label = ctx.cfg.blocks[(sz)entry.latch].label, .value = wide_next };
}

<* The i64 value equal to `sext ref` (`ref` has type `narrow`). *>
fn ir::Ref widen_value(WidenContext* ctx, ir::Ref ref, value_interner::InternerRef narrow, uint depth)
{
	if (ctx.wide[(sz)ref] != ir::NONE) return ctx.wide[(sz)ref];
	ir::Inst inst = ctx.editor.insts.entries[(sz)ref];
	ushort width;
	ulong bits;
	if (const_prop_int_width(ctx.graph, narrow, &width) &&
		scalar_constant_bits(ctx.graph, ctx.editor.insts.array_view(), ref, &bits))
	{
		ir::Ref constant = scalar_constant(ctx.graph, ctx.editor, 64, (ulong)const_prop_signed(bits, width), value_interner::REF_I64);
		ctx.wide[(sz)ref] = constant;
		return constant;
	}
	uint iv = ctx.iv_of[(sz)ref];
	if (iv != NONE_BLOCK)
	{
		widen_make_iv(ctx, iv);
		return ctx.wide[(sz)ref];
	}
	ir::Ref result;
	uint home = ctx.cfg.block_of_ref[(sz)ref];
	bool in_loop = home != NONE_BLOCK && (usz)home < (usz)ctx.loops.innermost_of_block.len &&
		ctx.loops.innermost_of_block[(sz)home] != NONE_BLOCK;
	if (inst.nsw && inst.tag.allows_nsw() && in_loop && depth < WIDEN_MAX_DEPTH)
	{
		ir::Ref lhs = widen_value(ctx, inst.data.bin.lhs, narrow, depth + 1);
		ir::Ref rhs = widen_value(ctx, inst.data.bin.rhs, narrow, depth + 1);
		result = ctx.editor.append({ .tag = inst.tag, .nsw = true, .data.bin = { lhs, rhs }, .ty = value_interner::REF_I64 });
	}
	else
	{
		result = ctx.editor.append({ .tag = ir::InstTag.SEXT, .data.ref = ref, .ty = value_interner::REF_I64 });
	}
	widen_place_after(ctx, widen_anchor(ctx, ref), result);
	ctx.wide[(sz)ref] = result;
	return result;
}

<* Rebuild the body with the new instructions after their anchors, dropping refs marked in `drop`. *>
fn void widen_rebuild_body(WidenContext* ctx, bool[] drop)
{
	DeclEditor* editor = ctx.editor;
	sz old_len = editor.body.len();
	ir::Ref[] old_body = alloc::new_array(tmem, ir::Ref, old_len);
	for (sz i = 0; i < old_len; i++) old_body[i] = editor.body.entries[i];
	uint[] first = alloc::new_array(tmem, uint, (sz)ctx.original_len + 1);
	first[..] = 0;
	foreach (insert : ctx.inserts) first[(sz)insert.anchor + 1]++;
	for (usz i = 0; i < ctx.original_len; i++) first[i + 1] += first[i];
	uint[] fill = alloc::new_array(tmem, uint, (sz)ctx.original_len);
	for (usz i = 0; i < ctx.original_len; i++) fill[i] = first[i];
	ir::Ref[] ordered = alloc::new_array(tmem, ir::Ref, ctx.inserts.len());
	foreach (insert : ctx.inserts) ordered[(sz)fill[(sz)insert.anchor]++] = insert.inst;
	editor.body.clear();
	foreach (ref : old_body)
	{
		if ((usz)ref >= ctx.original_len) { editor.body.push(ref); continue; }
		if (!drop[(sz)ref]) editor.body.push(ref);
		for (uint k = first[(sz)ref]; k < first[(sz)ref + 1]; k++) editor.body.push(ordered[(sz)k]);
	}
}

fn bool indvar_widen(ir::Ir* graph, ir::Decl* decl, FunctionAnalyses* cached = null)
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
		WidenContext ctx = { .graph = graph, .decl = decl, .editor = &editor, .cfg = cfg, .loops = loops,
			.original_len = decl.instructions.len };
		ctx.wide = alloc::new_array(tmem, ir::Ref, decl.instructions.len);
		ctx.wide[..] = ir::NONE;
		ctx.iv_of = alloc::new_array(tmem, uint, decl.instructions.len);
		ctx.iv_of[..] = NONE_BLOCK;
		ctx.ivs.init(mem);
		defer ctx.ivs.free();
		ctx.inserts.init(mem);
		defer ctx.inserts.free();
		foreach (loop_index, loop : loops.loops)
		{
			if (loop.header == 0 || loop.latches.len() != 1) continue;
			uint preheader = loop_existing_preheader(decl, cfg, loops, (uint)loop_index);
			if (preheader == NONE_BLOCK) continue;
			uint latch = loop.latches.entries[0];
			list::List{BasicIndVar} found;
			found.init(mem);
			defer found.free();
			loop_basic_ivs(graph, decl, cfg, loops, (uint)loop_index, preheader, latch, &found);
			foreach (iv : found)
			{
				if (iv.width >= 64 || !decl.instructions[(sz)iv.next].nsw) continue;
				if (ctx.iv_of[(sz)iv.phi] != NONE_BLOCK || ctx.iv_of[(sz)iv.next] != NONE_BLOCK) continue;
				uint index = (uint)ctx.ivs.len();
				ctx.ivs.push({ .iv = iv, .loop_index = (uint)loop_index, .preheader = preheader, .latch = latch,
					.wide_phi = ir::NONE, .wide_next = ir::NONE });
				ctx.iv_of[(sz)iv.phi] = index;
				ctx.iv_of[(sz)iv.next] = index;
			}
		}
		if (!ctx.ivs.len()) { editor.free(); return preheaders_changed; }
		bool changed = false;
		// Replaced roots are dead; drop them now so they do not keep the narrow IV alive.
		bool[] drop = alloc::new_array(tmem, bool, (sz)ctx.original_len);
		drop[..] = false;
		// Roots: `sext i64 x` inside a loop whose extension can move to cheap leaves.
		foreach (ref : decl.body)
		{
			ir::Inst root = decl.instructions[(sz)ref];
			if (root.tag != ir::InstTag.SEXT || root.ty != value_interner::REF_I64) continue;
			ir::Ref operand = root.data.ref;
			if ((usz)operand >= ctx.original_len) continue;
			ir::Inst narrow_inst = decl.instructions[(sz)operand];
			if (!(narrow_inst.nsw && narrow_inst.tag.allows_nsw()) && ctx.iv_of[(sz)operand] == NONE_BLOCK) continue;
			uint home = cfg.block_of_ref[(sz)ref];
			if (home == NONE_BLOCK || (usz)home >= (usz)loops.innermost_of_block.len) continue;
			uint loop_index = loops.innermost_of_block[(sz)home];
			if (loop_index == NONE_BLOCK) continue;
			Loop* loop = &loops.loops.entries[(sz)loop_index];
			if (!widen_profitable(&ctx, operand, narrow_inst.ty, loop, 0)) continue;
			ir::Ref replacement = widen_value(&ctx, operand, narrow_inst.ty, 0);
			editor_replace_all_uses(&editor, ref, replacement);
			drop[(sz)ref] = true;
			changed = true;
		}
		if (!changed) { editor.free(); return preheaders_changed; }
		// Signed / equality compares of a widened IV against an invariant: compare the
		// twins instead. sext is injective and order-preserving for signed values.
		foreach (ref : decl.body)
		{
			ir::Inst cmp = editor.insts.entries[(sz)ref];
			if (!widen_is_iv_compare(cmp.tag)) continue;
			ir::Ref a = cmp.data.bin.lhs;
			ir::Ref b = cmp.data.bin.rhs;
			if ((usz)a >= ctx.original_len || (usz)b >= ctx.original_len) continue;
			value_interner::InternerRef narrow = editor.insts.entries[(sz)a].ty;
			if (editor.insts.entries[(sz)b].ty != narrow || narrow == value_interner::REF_I64) continue;
			ir::Ref iv_side = ctx.iv_of[(sz)a] != NONE_BLOCK && ctx.wide[(sz)a] != ir::NONE ? a : b;
			ir::Ref other = iv_side == a ? b : a;
			if (ctx.iv_of[(sz)iv_side] == NONE_BLOCK || ctx.wide[(sz)iv_side] == ir::NONE) continue;
			Loop* loop = &loops.loops.entries[(sz)ctx.ivs.entries[(sz)ctx.iv_of[(sz)iv_side]].loop_index];
			if (ctx.wide[(sz)other] == ir::NONE && !widen_invariant(&ctx, other, loop)) continue;
			ir::Ref wide_a = widen_value(&ctx, a, narrow, 0);
			ir::Ref wide_b = widen_value(&ctx, b, narrow, 0);
			editor.insts.entries[(sz)ref].data.bin = { wide_a, wide_b };
		}
		// A narrow IV whose PHI and update now only feed each other is dead.
		uint[] users = alloc::new_array(tmem, uint, editor.insts.len());
		users[..] = 0;
		foreach (ref : editor.body)
		{
			if ((usz)ref < ctx.original_len && drop[(sz)ref]) continue;
			@each_value_operand(&editor.insts.entries[(sz)ref]; ir::Ref* slot)
			{
				if ((usz)*slot < (usz)users.len) users[(sz)*slot]++;
			};
		}
		foreach (insert : ctx.inserts)
		{
			@each_value_operand(&editor.insts.entries[(sz)insert.inst]; ir::Ref* slot)
			{
				if ((usz)*slot < (usz)users.len) users[(sz)*slot]++;
			};
		}
		// Narrow arithmetic orphaned by the rewrite is dead now; sweep it so it
		// does not keep the narrow IV alive.
		list::List{ir::Ref} dead;
		dead.init(mem);
		defer dead.free();
		foreach (ref : decl.body)
		{
			if ((usz)ref >= ctx.original_len || drop[(sz)ref] || users[(sz)ref] != 0) continue;
			if (widen_sweepable(editor.insts.entries[(sz)ref].tag)) dead.push(ref);
		}
		while (dead.len())
		{
			ir::Ref ref = dead.pop()!!;
			if (drop[(sz)ref]) continue;
			drop[(sz)ref] = true;
			@each_value_operand(&editor.insts.entries[(sz)ref]; ir::Ref* slot)
			{
				if ((usz)*slot >= ctx.original_len || users[(sz)*slot] == 0) continue;
				users[(sz)*slot]--;
				if (users[(sz)*slot] == 0 && !drop[(sz)*slot] &&
					widen_sweepable(editor.insts.entries[(sz)*slot].tag)) dead.push(*slot);
			};
		}
		foreach (entry : ctx.ivs)
		{
			if (entry.wide_phi == ir::NONE) continue;
			ir::Inst next = editor.insts.entries[(sz)entry.iv.next];
			uint next_self = (next.data.bin.lhs == entry.iv.phi ? 1 : 0) + (next.data.bin.rhs == entry.iv.phi ? 1 : 0);
			if (users[(sz)entry.iv.phi] == next_self && users[(sz)entry.iv.next] == 1)
			{
				drop[(sz)entry.iv.phi] = true;
				drop[(sz)entry.iv.next] = true;
			}
		}
		widen_rebuild_body(&ctx, drop);
		editor.commit();
		return true;
	};
}
