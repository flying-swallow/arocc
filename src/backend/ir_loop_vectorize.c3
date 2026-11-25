// Inner-loop vectorizer (SSE2, 128-bit; see `ir::VectorShape`). Handles the
// canonical two-block counted loop that `indvar_widen` leaves:
//
//   H: iv = phi [init, P], [iv + 1, B]; r = phi ...; branch iv < bound, B, exit
//   B: contiguous loads/stores at `base + iv*size`, lane-wise arithmetic,
//      integer `r = r + x` reductions; jmp H
//
// It versions the loop: P computes the trip count and, when at least one full
// vector of iterations remains and no stored range overlaps another accessed
// range, branches to a vector copy that runs `cnt & -VF` iterations; the
// original loop then runs the remainder from where the vector loop stopped:
//
//   P: checks; branch ok, VPH, SPH
//   VPH: splats; jmp VH
//   VH: viv, vacc phis; branch viv < vend, VB, MID
//   VB: vector body; viv += VF; jmp VH
//   MID: r += reduce(vacc); jmp SPH
//   SPH: iv, r phis [P: init], [MID: vend / r]; jmp H (the original loop)
//
// Float reductions are not vectorized (they would reassociate).
module aro::backend::ir_opt;
import aro::backend::ir, aro::value_interner;
import std::collections::list;

const uint VEC_MAX_RUNTIME_CHECKS = 8;

enum VecKind : char
{
	OUTSIDE,
	IV_PHI,
	IV_NEXT,
	RED_PHI,
	RED_ADD,
	<* A scalar computed once per vector iteration: loop-uniform, or an affine
	   function of the IV (address arithmetic, evaluated at lane 0). *>
	SCALAR,
	VARYING,
	STORE,
}

struct VecAccess
{
	ir::Ref inst;
	ir::Ref address;
	bool is_store;
}

struct VecReduction
{
	ir::Ref phi;
	ir::Ref add;
	ir::Ref init;
}

struct VecPlan
{
	uint loop_index;
	uint preheader;
	uint latch;
	uint exit;
	BasicIndVar iv;
	ir::Ref bound;
	bool inclusive;
	value_interner::InternerRef lane;
	ushort lane_bits;
	bool lane_float;
	list::List{VecReduction} reductions;
	list::List{VecAccess} accesses;
}

struct VecContext
{
	ir::Ir* graph;
	ir::Decl* decl;
	Cfg* cfg;
	LoopInfo* loops;
	Uses* uses;
	DeclEditor* editor;
	usz original_len;
	VecKind[] kind;
	bool[] iv_dep;
	LsrContext lsr;
}

fn void VecPlan.free(&self)
{
	self.reductions.free();
	self.accesses.free();
}

fn bool vec_lane_type(ir::Ir* graph, value_interner::InternerRef ty, ushort* bits, bool* is_float)
{
	if (ty == value_interner::REF_PTR || ty == value_interner::REF_I1) return false;
	if (ty == value_interner::REF_I32 || ty == value_interner::REF_I64) { *bits = ty == value_interner::REF_I32 ? 32 : 64; *is_float = false; return true; }
	// 8 / 16-bit lanes: C `char` / `short` loops once narrow_truncated_arith drops the promotions.
	if (ty == value_interner::REF_I8 || ty == value_interner::REF_I16) { *bits = ty == value_interner::REF_I8 ? 8 : 16; *is_float = false; return true; }
	if (ty == value_interner::REF_F32 || ty == value_interner::REF_F64) { *bits = ty == value_interner::REF_F32 ? 32 : 64; *is_float = true; return true; }
	return false;
}

<* All vector values of one loop share one lane type. *>
fn bool vec_unify_lane(ir::Ir* graph, VecPlan* plan, value_interner::InternerRef ty)
{
	ushort bits;
	bool is_float;
	if (!vec_lane_type(graph, ty, &bits, &is_float)) return false;
	if (plan.lane == value_interner::REF_VOID)
	{
		plan.lane = ty;
		plan.lane_bits = bits;
		plan.lane_float = is_float;
		return true;
	}
	return plan.lane == ty;
}

<* Lane-wise op tags the x86 lowering supports for `plan`'s lane type
   (`ir::sse2_vector_op`). Compares are excluded: their scalar i1 result is not
   a lane value. Shifts also need a loop-uniform count (checked in vec_analyze). *>
fn bool vec_tag_ok(VecPlan* plan, ir::InstTag tag)
{
	if (!vec_is_pure_scalar(tag)) return false;
	ir::VectorShape shape = { .lanes = 128 / plan.lane_bits, .elem = plan.lane, .elem_bits = plan.lane_bits, .is_float = plan.lane_float };
	return ir::sse2_vector_op(tag, shape);
}

fn bool vec_is_shift(ir::InstTag tag) => tag == ir::InstTag.BIT_SHL || tag == ir::InstTag.BIT_ASHR || tag == ir::InstTag.BIT_LSHR;

fn bool vec_is_unary(ir::InstTag tag) => tag == ir::InstTag.NEGATE || tag == ir::InstTag.BIT_NOT || tag == ir::InstTag.FNEG;

<* `address` advances by exactly `size` bytes per IV step: base (invariant) plus an affine i64 offset. *>
fn bool vec_contiguous(VecContext* ctx, ir::Ref address, uint size, uint depth = 0)
{
	if (depth > LSR_MAX_DEPTH || (usz)address >= ctx.original_len) return false;
	long stride = 0;
	ir::Ref current = address;
	while (true)
	{
		if (lsr_invariant(&ctx.lsr, current)) break;
		ir::Inst inst = ctx.editor.insts.entries[(sz)current];
		if (inst.tag != ir::InstTag.ADD || inst.ty != value_interner::REF_PTR) return false;
		LsrCoeff coeff;
		ctx.lsr.has_invariant_leaf = false;
		if (!lsr_affine(&ctx.lsr, inst.data.bin.rhs, &coeff, 0) || coeff.r != ir::NONE) return false;
		stride += coeff.c;
		current = inst.data.bin.lhs;
		if (++depth > LSR_MAX_DEPTH) return false;
	}
	return stride == (long)size;
}

fn bool vec_operand_uniform(VecContext* ctx, ir::Ref ref)
{
	if ((usz)ref >= ctx.original_len) return true;
	VecKind k = ctx.kind[(sz)ref];
	return (k == VecKind.OUTSIDE || k == VecKind.SCALAR) && !ctx.iv_dep[(sz)ref];
}

fn bool vec_is_pure_scalar(ir::InstTag tag)
{
	switch (tag)
	{
		case ADD:
		case SUB:
		case MUL:
		case NEGATE:
		case BIT_AND:
		case BIT_OR:
		case BIT_XOR:
		case BIT_SHL:
		case BIT_ASHR:
		case BIT_LSHR:
		case BIT_NOT:
		case SEXT:
		case ZEXT:
		case TRUNC:
		case FADD:
		case FSUB:
		case FMUL:
		case FDIV:
		case FNEG: return true;
		default: return false;
	}
}

<* Build a plan for loop `loop_index`, or fail. *>
fn bool vec_analyze(VecContext* ctx, uint loop_index, VecPlan* plan)
{
	ir::Decl* decl = ctx.decl;
	Cfg* cfg = ctx.cfg;
	LoopInfo* loops = ctx.loops;
	Loop* loop = &loops.loops.entries[(sz)loop_index];
	if (loop.header == 0 || loop.latches.len() != 1 || loop.blocks.len() != 2) return false;
	foreach (other : loops.loops) if (other.parent == loop_index) return false;
	uint preheader = loop_existing_preheader(decl, cfg, loops, loop_index);
	if (preheader == NONE_BLOCK) return false;
	uint latch = loop.latches.entries[0];
	if (latch == loop.header) return false;
	CfgBlock* header = &cfg.blocks[(sz)loop.header];
	CfgBlock* body = &cfg.blocks[(sz)latch];
	if (body.preds.len() != 1 || body.succs.len() != 1) return false;
	// Header: PHIs, the exit compare, the branch.
	sz term_pos = block_terminator_position(decl, header);
	if (term_pos >= header.end) return false;
	ir::Inst branch = decl.instructions[(sz)decl.body[term_pos]];
	if (branch.tag != ir::InstTag.BRANCH) return false;
	uint then_block = indvar_block_for_label(cfg, branch.data.branch.then_label);
	uint else_block = indvar_block_for_label(cfg, branch.data.branch.else_label);
	if (then_block != latch || else_block == NONE_BLOCK || loop_body_contains(loop, else_block)) return false;
	ir::Ref cmp_ref = branch.data.branch.cond;
	if ((usz)cmp_ref >= ctx.original_len || cfg.block_of_ref[(sz)cmp_ref] != loop.header || ctx.uses.of(cmp_ref).len != 1) return false;
	ir::Inst cmp = decl.instructions[(sz)cmp_ref];
	ir::Ref iv_side;
	switch (cmp.tag)
	{
		case CMP_SLT: iv_side = cmp.data.bin.lhs; plan.bound = cmp.data.bin.rhs; plan.inclusive = false;
		case CMP_SLTE: iv_side = cmp.data.bin.lhs; plan.bound = cmp.data.bin.rhs; plan.inclusive = true;
		case CMP_SGT: iv_side = cmp.data.bin.rhs; plan.bound = cmp.data.bin.lhs; plan.inclusive = false;
		case CMP_SGTE: iv_side = cmp.data.bin.rhs; plan.bound = cmp.data.bin.lhs; plan.inclusive = true;
		default: return false;
	}
	ctx.lsr.loop = loop;
	if ((usz)plan.bound >= ctx.original_len || !lsr_invariant(&ctx.lsr, plan.bound)) return false;
	list::List{BasicIndVar} ivs;
	ivs.init(mem);
	defer ivs.free();
	loop_basic_ivs(ctx.graph, decl, cfg, loops, loop_index, preheader, latch, &ivs);
	bool found = false;
	foreach (iv : ivs)
	{
		if (iv.phi == iv_side) { plan.iv = iv; found = true; break; }
	}
	if (!found || plan.iv.ty != value_interner::REF_I64 || plan.iv.step_bits != 1) return false;
	if (!lftr_int32_range(ctx.graph, decl.instructions, plan.iv.init) || !lftr_int32_range(ctx.graph, decl.instructions, plan.bound)) return false;
	if (cfg.block_of_ref[(sz)plan.iv.next] != latch || ctx.uses.of(plan.iv.next).len != 1) return false;
	plan.loop_index = loop_index;
	plan.preheader = preheader;
	plan.latch = latch;
	plan.exit = else_block;
	plan.lane = value_interner::REF_VOID;
	ctx.lsr.iv = &plan.iv;
	ctx.kind[(sz)plan.iv.phi] = VecKind.IV_PHI;
	ctx.iv_dep[(sz)plan.iv.phi] = true;
	ctx.kind[(sz)plan.iv.next] = VecKind.IV_NEXT;
	for (sz pos = header.start + 1; pos < header.end; pos++)
	{
		ir::Ref ref = decl.body[pos];
		ir::Inst inst = decl.instructions[(sz)ref];
		if (ref == cmp_ref || ref == decl.body[term_pos]) continue;
		if (inst.tag != ir::InstTag.PHI) return false;
		if (ref == plan.iv.phi) continue;
		// Integer sum reduction: r = phi [init, P], [r + x, B]; r + x feeds only the PHI.
		if (inst.data.phi.len != 2 || plan.lane_float) return false;
		ir::Ref init = ir::NONE;
		ir::Ref update = ir::NONE;
		foreach (input : inst.data.phi)
		{
			if (input.label == cfg.blocks[(sz)preheader].label)
			{
				init = input.value;
			}
			else if (input.label == cfg.blocks[(sz)latch].label)
			{
				update = input.value;
			}
		}
		if (init == ir::NONE || update == ir::NONE || (usz)update >= ctx.original_len) return false;
		ir::Inst add = decl.instructions[(sz)update];
		if (add.tag != ir::InstTag.ADD || add.ty != inst.ty || cfg.block_of_ref[(sz)update] != latch) return false;
		if (add.data.bin.lhs != ref && add.data.bin.rhs != ref) return false;
		if (add.data.bin.lhs == ref && add.data.bin.rhs == ref) return false;
		if (ctx.uses.of(update).len != 1) return false;
		// The running sum is only read by its update inside the loop.
		foreach (user : ctx.uses.of(ref))
		{
			if (user == update) continue;
			uint home = cfg.block_of_ref[(sz)user];
			if (home == NONE_BLOCK || loop_body_contains(loop, home)) return false;
		}
		if (!vec_unify_lane(ctx.graph, plan, inst.ty) || plan.lane_float) return false;
		ctx.kind[(sz)ref] = VecKind.RED_PHI;
		ctx.kind[(sz)update] = VecKind.RED_ADD;
		plan.reductions.push({ .phi = ref, .add = update, .init = init });
	}
	// Body classification, in order (operands come first).
	sz body_term = block_terminator_position(decl, body);
	if (body_term >= body.end || decl.instructions[(sz)decl.body[body_term]].tag != ir::InstTag.JMP) return false;
	for (sz pos = body.start + 1; pos < body_term; pos++)
	{
		ir::Ref ref = decl.body[pos];
		ir::Inst inst = decl.instructions[(sz)ref];
		if (inst.tag == ir::InstTag.PHI) return false;
		VecKind k = ctx.kind[(sz)ref];
		if (k == VecKind.IV_NEXT) continue;
		if (k == VecKind.RED_ADD)
		{
			ir::Ref phi = inst.data.bin.lhs;
			ir::Ref x = inst.data.bin.rhs;
			if (ctx.kind[(sz)x] == VecKind.RED_PHI) { ir::Ref t = phi; phi = x; x = t; }
			if ((usz)x < ctx.original_len && ctx.kind[(sz)x] != VecKind.VARYING && !vec_operand_uniform(ctx, x)) return false;
			if (ctx.editor.insts.entries[(sz)x].ty != plan.lane) return false;
			continue;
		}
		switch (inst.tag)
		{
			case LOAD:
				if (inst.is_volatile || !vec_unify_lane(ctx.graph, plan, inst.ty)) return false;
				if ((usz)inst.data.ref < ctx.original_len && ctx.kind[(sz)inst.data.ref] == VecKind.VARYING) return false;
				if (!vec_contiguous(ctx, inst.data.ref, plan.lane_bits / 8)) return false;
				ctx.kind[(sz)ref] = VecKind.VARYING;
				plan.accesses.push({ .inst = ref, .address = inst.data.ref, .is_store = false });
			case STORE:
				if (inst.is_volatile) return false;
				ir::Ref value = inst.data.bin.rhs;
				ir::Ref address = inst.data.bin.lhs;
				if (!vec_unify_lane(ctx.graph, plan, ctx.editor.insts.entries[(sz)value].ty)) return false;
				if ((usz)value < ctx.original_len && ctx.kind[(sz)value] != VecKind.VARYING && !vec_operand_uniform(ctx, value)) return false;
				if ((usz)address < ctx.original_len && ctx.kind[(sz)address] == VecKind.VARYING) return false;
				if (!vec_contiguous(ctx, address, plan.lane_bits / 8)) return false;
				ctx.kind[(sz)ref] = VecKind.STORE;
				plan.accesses.push({ .inst = ref, .address = address, .is_store = true });
			default:
				if (!vec_is_pure_scalar(inst.tag)) return false;
				bool varying = false;
				bool dependent = false;
				bool has_red = false;
				@each_value_operand(&inst; ir::Ref* slot)
				{
					if ((usz)*slot < ctx.original_len)
					{
						VecKind ok = ctx.kind[(sz)*slot];
						if (ok == VecKind.VARYING) varying = true;
						if (ok == VecKind.RED_PHI) has_red = true;
						if (ctx.iv_dep[(sz)*slot]) dependent = true;
					}
				};
				if (has_red) return false;
				if (varying)
				{
					// A lane-wise op: other operands must be loop-uniform (splatted).
					if (dependent || inst.ty != plan.lane || !vec_tag_ok(plan, inst.tag)) return false;
					if (vec_is_shift(inst.tag))
					{
						// SSE2 shifts every lane by one count: a uniform lane-typed scalar (splatted).
						ir::Ref count = inst.data.bin.rhs;
						if ((usz)count < ctx.original_len && ctx.kind[(sz)count] == VecKind.VARYING) return false;
						// A count of another width (`i64 >> i32 5`) must be a constant: it is
						// re-made in the lane type before the splat.
						ulong count_bits;
						if (ctx.editor.insts.entries[(sz)count].ty != plan.lane &&
							(!scalar_constant_bits(ctx.graph, ctx.editor.insts.array_view(), count, &count_bits) || count_bits >= plan.lane_bits)) return false;
					}
					ctx.kind[(sz)ref] = VecKind.VARYING;
				}
				else
				{
					if (dependent)
					{
						// IV arithmetic: only address math (ADD/SUB/MUL/SHL/NEGATE on i64/ptr).
						if (inst.ty != value_interner::REF_I64 && inst.ty != value_interner::REF_PTR) return false;
						if (inst.tag != ir::InstTag.ADD && inst.tag != ir::InstTag.SUB && inst.tag != ir::InstTag.MUL &&
							inst.tag != ir::InstTag.BIT_SHL && inst.tag != ir::InstTag.NEGATE) return false;
						ctx.iv_dep[(sz)ref] = true;
					}
					ctx.kind[(sz)ref] = VecKind.SCALAR;
				}
		}
	}
	if (plan.lane == value_interner::REF_VOID || !plan.accesses.len()) return false;
	// IV-dependent scalars may only feed addresses (or other IV arithmetic).
	for (sz pos = body.start + 1; pos < body_term; pos++)
	{
		ir::Ref ref = decl.body[pos];
		if (!ctx.iv_dep[(sz)ref]) continue;
		foreach (user : ctx.uses.of(ref))
		{
			ir::Inst u = decl.instructions[(sz)user];
			if ((usz)user < ctx.original_len && ctx.iv_dep[(sz)user]) continue;
			if (u.tag == ir::InstTag.LOAD && u.data.ref == ref) continue;
			if (u.tag == ir::InstTag.STORE && u.data.bin.lhs == ref && u.data.bin.rhs != ref) continue;
			return false;
		}
	}
	foreach (user : ctx.uses.of(plan.iv.phi))
	{
		if (user == plan.iv.next || user == cmp_ref) continue;
		ir::Inst u = decl.instructions[(sz)user];
		uint home = cfg.block_of_ref[(sz)user];
		if (home == NONE_BLOCK || !loop_body_contains(loop, home)) continue;
		if ((usz)user < ctx.original_len && ctx.iv_dep[(sz)user]) continue;
		if (u.tag == ir::InstTag.LOAD && u.data.ref == plan.iv.phi) continue;
		return false;
	}
	// Runtime checks: each store against every access at a different address.
	uint checks = 0;
	foreach (s : plan.accesses)
	{
		if (!s.is_store) continue;
		foreach (a : plan.accesses)
		{
			if (a.inst == s.inst || a.address == s.address) continue;
			if (a.is_store && a.inst < s.inst) continue;
			checks++;
		}
	}
	return checks <= VEC_MAX_RUNTIME_CHECKS;
}

struct VecBuild
{
	VecContext* ctx;
	VecPlan* plan;
	List{LsrInsert}* pre;
	List{ir::Ref}* blocks;
	sz pre_pos;
	ir::Ref[] scalar_map;
	ir::Ref[] vector_map;
	ir::Ref[] splat_outside;
	ir::Ref vector_iv;
}

fn ir::Ref vec_emit(VecBuild* b, ir::Inst inst)
{
	ir::Ref ref = b.ctx.editor.append(inst);
	b.blocks.push(ref);
	return ref;
}

fn ir::Ref vec_emit_pre(VecBuild* b, ir::Inst inst)
{
	ir::Ref ref = b.ctx.editor.append(inst);
	b.pre.push({ .before = b.pre_pos, .inst = ref });
	return ref;
}

<* The vector form of `ref` inside the vector body: its lane-wise copy, or a splat of a uniform scalar. *>
fn ir::Ref vec_vector_operand(VecBuild* b, ir::Ref ref, value_interner::InternerRef vty, List{ir::Ref}* outside_splats)
{
	if ((usz)ref < b.ctx.original_len && b.vector_map[(sz)ref] != ir::NONE) return b.vector_map[(sz)ref];
	if ((usz)ref < b.ctx.original_len && b.ctx.kind[(sz)ref] == VecKind.SCALAR)
	{
		ir::Ref splat = vec_emit(b, { .tag = ir::InstTag.VSPLAT, .data.ref = b.scalar_map[(sz)ref], .ty = vty });
		b.vector_map[(sz)ref] = splat;
		return splat;
	}
	// Defined outside the loop (or a constant): splat once in the vector preheader.
	if ((usz)ref < b.ctx.original_len && b.splat_outside[(sz)ref] != ir::NONE) return b.splat_outside[(sz)ref];
	ir::Ref splat = b.ctx.editor.append({ .tag = ir::InstTag.VSPLAT, .data.ref = ref, .ty = vty });
	outside_splats.push(splat);
	if ((usz)ref < b.ctx.original_len) b.splat_outside[(sz)ref] = splat;
	return splat;
}

fn ir::Ref vec_scalar_operand(VecBuild* b, ir::Ref ref)
{
	if ((usz)ref < b.ctx.original_len && b.scalar_map[(sz)ref] != ir::NONE) return b.scalar_map[(sz)ref];
	return ref;
}

fn bool loop_vectorize(ir::Ir* graph, ir::Decl* decl, FunctionAnalyses* cached = null)
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
		DeclEditor editor;
		editor.begin(decl);
		usz original_len = decl.instructions.len;
		VecContext ctx = { .graph = graph, .decl = decl, .cfg = cfg, .loops = loops, .uses = analyses.get_uses(),
			.editor = &editor, .original_len = original_len };
		ctx.lsr = { .graph = graph, .decl = decl, .editor = &editor, .cfg = cfg, .original_len = original_len };
		ctx.lsr.inserts.init(mem);
		defer ctx.lsr.inserts.free();
		ctx.kind = alloc::new_array(tmem, VecKind, (sz)original_len);
		ctx.iv_dep = alloc::new_array(tmem, bool, (sz)original_len);
		List{LsrInsert} pre;
		pre.init(mem);
		defer pre.free();
		// Header body position -> the new block group inserted before it.
		List{ir::Ref}[] groups = alloc::new_array(tmem, List{ir::Ref}, (sz)decl.body.len + 1);
		bool changed = false;
		foreach (loop_index, &loop : loops.loops)
		{
			ctx.kind[..] = VecKind.OUTSIDE;
			ctx.iv_dep[..] = false;
			VecPlan plan;
			plan.reductions.init(mem);
			plan.accesses.init(mem);
			defer plan.free();
			if (!vec_analyze(&ctx, (uint)loop_index, &plan)) continue;
			vec_transform(&ctx, &plan, &pre, &groups[(sz)cfg.blocks[(sz)loop.header].start]);
			changed = true;
		}
		if (!changed) { editor.free(); return false; }
		sz old_len = editor.body.len();
		ir::Ref[] old_body = alloc::new_array(tmem, ir::Ref, old_len);
		for (sz i = 0; i < old_len; i++) old_body[i] = editor.body.entries[i];
		editor.body.clear();
		for (sz pos = 0; pos <= old_len; pos++)
		{
			foreach (insert : pre) if (insert.before == pos) editor.body.push(insert.inst);
			foreach (ref : groups[pos]) editor.body.push(ref);
			if (pos < old_len) editor.body.push(old_body[pos]);
		}
		foreach (&group : groups) group.free();
		editor.commit();
		return true;
	};
}

fn void vec_transform(VecContext* ctx, VecPlan* plan, List{LsrInsert}* pre, List{ir::Ref}* group)
{
	ir::Ir* graph = ctx.graph;
	ir::Decl* decl = ctx.decl;
	Cfg* cfg = ctx.cfg;
	DeclEditor* editor = ctx.editor;
	Loop* loop = &ctx.loops.loops.entries[(sz)plan.loop_index];
	CfgBlock* pre_block = &cfg.blocks[(sz)plan.preheader];
	CfgBlock* header = &cfg.blocks[(sz)loop.header];
	CfgBlock* body = &cfg.blocks[(sz)plan.latch];
	sz pre_term = block_terminator_position(decl, pre_block);
	uint lanes = 128 / plan.lane_bits;
	value_interner::InternerRef vty = graph.vector_type(plan.lane);
	group.init(mem);
	VecBuild b = { .ctx = ctx, .plan = plan, .pre = pre, .blocks = group, .pre_pos = pre_term };
	b.scalar_map = alloc::new_array(tmem, ir::Ref, (sz)ctx.original_len);
	b.vector_map = alloc::new_array(tmem, ir::Ref, (sz)ctx.original_len);
	b.splat_outside = alloc::new_array(tmem, ir::Ref, (sz)ctx.original_len);
	b.scalar_map[..] = ir::NONE;
	b.vector_map[..] = ir::NONE;
	b.splat_outside[..] = ir::NONE;
	value_interner::InternerRef i64 = value_interner::REF_I64;
	value_interner::InternerRef i1 = value_interner::REF_I1;
	// P: cnt = max(limit - init, 0); vend = init + (cnt & -lanes).
	ir::Ref limit = plan.bound;
	if (plan.inclusive)
	{
		limit = vec_emit_pre(&b, { .tag = ir::InstTag.ADD, .data.bin = { plan.bound, scalar_constant(graph, editor, 64, 1, i64) }, .ty = i64 });
	}
	ir::Ref zero = scalar_constant(graph, editor, 64, 0, i64);
	ir::Ref diff = vec_emit_pre(&b, { .tag = ir::InstTag.SUB, .data.bin = { limit, plan.iv.init }, .ty = i64 });
	ir::Ref negative = vec_emit_pre(&b, { .tag = ir::InstTag.CMP_SLT, .data.bin = { diff, zero }, .ty = i1 });
	ir::Ref count = vec_emit_pre(&b, { .tag = ir::InstTag.SELECT, .data.branch = { negative, zero, diff }, .ty = i64 });
	ir::Ref mask = scalar_constant(graph, editor, 64, (ulong)(0 - (long)lanes), i64);
	ir::Ref vcount = vec_emit_pre(&b, { .tag = ir::InstTag.BIT_AND, .data.bin = { count, mask }, .ty = i64 });
	ir::Ref vend = vec_emit_pre(&b, { .tag = ir::InstTag.ADD, .data.bin = { plan.iv.init, vcount }, .ty = i64 });
	ir::Ref ok = vec_emit_pre(&b, { .tag = ir::InstTag.CMP_NE, .data.bin = { vcount, zero }, .ty = i1 });
	// Overlap checks over the whole scalar range [addr(init), addr(limit)).
	ir::Ref true_bit = scalar_constant(graph, editor, 1, 1, i1);
	foreach (s : plan.accesses)
	{
		if (!s.is_store) continue;
		foreach (a : plan.accesses)
		{
			if (a.inst == s.inst || a.address == s.address) continue;
			if (a.is_store && a.inst < s.inst) continue;
			ctx.lsr.inserts.clear();
			ir::Ref s_lo = lsr_clone_at_init(&ctx.lsr, s.address, plan.iv.init, pre_term);
			ir::Ref s_hi = lsr_clone_at_init(&ctx.lsr, s.address, limit, pre_term);
			ir::Ref a_lo = lsr_clone_at_init(&ctx.lsr, a.address, plan.iv.init, pre_term);
			ir::Ref a_hi = lsr_clone_at_init(&ctx.lsr, a.address, limit, pre_term);
			foreach (insert : ctx.lsr.inserts) pre.push(insert);
			ir::Ref below = vec_emit_pre(&b, { .tag = ir::InstTag.CMP_ULT, .data.bin = { s_lo, a_hi }, .ty = i1 });
			ir::Ref above = vec_emit_pre(&b, { .tag = ir::InstTag.CMP_ULT, .data.bin = { a_lo, s_hi }, .ty = i1 });
			ir::Ref overlap = vec_emit_pre(&b, { .tag = ir::InstTag.BIT_AND, .data.bin = { below, above }, .ty = i1 });
			ir::Ref disjoint = vec_emit_pre(&b, { .tag = ir::InstTag.BIT_XOR, .data.bin = { overlap, true_bit }, .ty = i1 });
			ok = vec_emit_pre(&b, { .tag = ir::InstTag.BIT_AND, .data.bin = { ok, disjoint }, .ty = i1 });
		}
	}
	ir::Ref vph = editor.new_label("vec.ph");
	ir::Ref vh = editor.new_label("vec.cond");
	ir::Ref vb = editor.new_label("vec.body");
	ir::Ref mid = editor.new_label("vec.mid");
	ir::Ref sph = editor.new_label("vec.scalar");
	ir::Inst branch = { .tag = ir::InstTag.BRANCH, .data.branch = { ok, vph, sph }, .ty = value_interner::REF_NORETURN };
	if (pre_term < pre_block.end)
	{
		editor.insts.entries[(sz)decl.body[pre_term]] = branch;
	}
	else
	{
		vec_emit_pre(&b, branch);
	}
	// VPH: splats of loop-invariant operands (filled while cloning) and the zero accumulators.
	b.blocks.push(vph);
	List{ir::Ref} outside_splats;
	outside_splats.init(mem);
	defer outside_splats.free();
	ir::Ref lane_zero = scalar_constant(graph, editor, plan.lane_bits, 0, plan.lane);
	ir::Ref vzero = editor.append({ .tag = ir::InstTag.VSPLAT, .data.ref = lane_zero, .ty = vty });
	outside_splats.push(vzero);
	sz vph_jump_slot = b.blocks.len();
	b.blocks.push(ir::NONE);
	// VH: vector IV and accumulator PHIs.
	b.blocks.push(vh);
	ir::PhiInput[] iv_inputs = alloc::new_array(&decl.arena, ir::PhiInput, 2);
	ir::Ref viv = vec_emit(&b, { .tag = ir::InstTag.PHI, .data.phi = iv_inputs, .ty = i64 });
	b.scalar_map[(sz)plan.iv.phi] = viv;
	ir::Ref[] vacc = alloc::new_array(tmem, ir::Ref, plan.reductions.len());
	foreach (i, red : plan.reductions)
	{
		ir::PhiInput[] inputs = alloc::new_array(&decl.arena, ir::PhiInput, 2);
		vacc[i] = vec_emit(&b, { .tag = ir::InstTag.PHI, .data.phi = inputs, .ty = vty });
		b.vector_map[(sz)red.phi] = vacc[i];
	}
	ir::Ref vcmp = vec_emit(&b, { .tag = ir::InstTag.CMP_SLT, .data.bin = { viv, vend }, .ty = i1 });
	vec_emit(&b, { .tag = ir::InstTag.BRANCH, .data.branch = { vcmp, vb, mid }, .ty = value_interner::REF_NORETURN });
	// VB: the body, scalars at lane 0 and lane-wise vector copies.
	b.blocks.push(vb);
	sz body_term = block_terminator_position(decl, body);
	for (sz pos = body.start + 1; pos < body_term; pos++)
	{
		ir::Ref ref = decl.body[pos];
		ir::Inst inst = editor.insts.entries[(sz)ref];
		switch (ctx.kind[(sz)ref])
		{
			case IV_NEXT: break;
			case SCALAR:
				ir::Inst copy = inst;
				copy.nsw = false;
				@each_value_operand(&copy; ir::Ref* slot) { *slot = vec_scalar_operand(&b, *slot); };
				b.scalar_map[(sz)ref] = vec_emit(&b, copy);
			case VARYING:
				if (inst.tag == ir::InstTag.LOAD)
				{
					b.vector_map[(sz)ref] = vec_emit(&b, { .tag = ir::InstTag.LOAD, .data.ref = vec_scalar_operand(&b, inst.data.ref), .ty = vty });
					break;
				}
				if (vec_is_unary(inst.tag))
				{
					ir::Ref operand = vec_vector_operand(&b, inst.data.ref, vty, &outside_splats);
					b.vector_map[(sz)ref] = vec_emit(&b, { .tag = inst.tag, .data.ref = operand, .ty = vty });
					break;
				}
				ir::Ref lhs = vec_vector_operand(&b, inst.data.bin.lhs, vty, &outside_splats);
				ir::Ref shift_count = inst.data.bin.rhs;
				ulong count_bits;
				if (vec_is_shift(inst.tag) && editor.insts.entries[(sz)shift_count].ty != plan.lane &&
					scalar_constant_bits(graph, editor.insts.array_view(), shift_count, &count_bits))
				{
					shift_count = scalar_constant(graph, editor, plan.lane_bits, count_bits, plan.lane);
				}
				ir::Ref rhs = vec_vector_operand(&b, shift_count, vty, &outside_splats);
				b.vector_map[(sz)ref] = vec_emit(&b, { .tag = inst.tag, .data.bin = { lhs, rhs }, .ty = vty });
			case RED_ADD:
				ir::Ref x = ctx.kind[(sz)inst.data.bin.lhs] == VecKind.RED_PHI ? inst.data.bin.rhs : inst.data.bin.lhs;
				ir::Ref phi = ctx.kind[(sz)inst.data.bin.lhs] == VecKind.RED_PHI ? inst.data.bin.lhs : inst.data.bin.rhs;
				ir::Ref vx = vec_vector_operand(&b, x, vty, &outside_splats);
				b.vector_map[(sz)ref] = vec_emit(&b, { .tag = ir::InstTag.ADD, .data.bin = { b.vector_map[(sz)phi], vx }, .ty = vty });
			case STORE:
				ir::Ref value = vec_vector_operand(&b, inst.data.bin.rhs, vty, &outside_splats);
				vec_emit(&b, { .tag = ir::InstTag.STORE, .data.bin = { vec_scalar_operand(&b, inst.data.bin.lhs), value }, .ty = value_interner::REF_VOID });
			default:
				unreachable("unclassified vector loop instruction");
		}
	}
	ir::Ref step = scalar_constant(graph, editor, 64, lanes, i64);
	ir::Ref viv_next = vec_emit(&b, { .tag = ir::InstTag.ADD, .data.bin = { viv, step }, .ty = i64 });
	vec_emit(&b, { .tag = ir::InstTag.JMP, .data.ref = vh, .ty = value_interner::REF_NORETURN });
	iv_inputs = editor.insts.entries[(sz)viv].data.phi;
	iv_inputs[0] = { .label = vph, .value = plan.iv.init };
	iv_inputs[1] = { .label = vb, .value = viv_next };
	foreach (i, red : plan.reductions)
	{
		ir::PhiInput[] inputs = editor.insts.entries[(sz)vacc[i]].data.phi;
		inputs[0] = { .label = vph, .value = vzero };
		inputs[1] = { .label = vb, .value = b.vector_map[(sz)red.add] };
	}
	// MID: fold the accumulators into the scalar running sums.
	b.blocks.push(mid);
	ir::Ref[] mid_sum = alloc::new_array(tmem, ir::Ref, plan.reductions.len());
	foreach (i, red : plan.reductions)
	{
		value_interner::InternerRef ty = decl.instructions[(sz)red.phi].ty;
		ir::Ref lanes_sum = vec_emit(&b, { .tag = ir::InstTag.VREDUCE_ADD, .data.ref = vacc[i], .ty = ty });
		mid_sum[i] = vec_emit(&b, { .tag = ir::InstTag.ADD, .data.bin = { red.init, lanes_sum }, .ty = ty });
	}
	vec_emit(&b, { .tag = ir::InstTag.JMP, .data.ref = sph, .ty = value_interner::REF_NORETURN });
	// SPH: the remainder loop's starting IV and sums.
	b.blocks.push(sph);
	ir::Ref pre_label = pre_block.label;
	ir::PhiInput[] siv_inputs = alloc::new_array(&decl.arena, ir::PhiInput, 2);
	ir::Ref siv = vec_emit(&b, { .tag = ir::InstTag.PHI, .data.phi = siv_inputs, .ty = i64 });
	siv_inputs = editor.insts.entries[(sz)siv].data.phi;
	siv_inputs[0] = { .label = pre_label, .value = plan.iv.init };
	siv_inputs[1] = { .label = mid, .value = vend };
	ir::Ref[] sred = alloc::new_array(tmem, ir::Ref, plan.reductions.len());
	foreach (i, red : plan.reductions)
	{
		ir::PhiInput[] inputs = alloc::new_array(&decl.arena, ir::PhiInput, 2);
		sred[i] = vec_emit(&b, { .tag = ir::InstTag.PHI, .data.phi = inputs, .ty = decl.instructions[(sz)red.phi].ty });
		inputs = editor.insts.entries[(sz)sred[i]].data.phi;
		inputs[0] = { .label = pre_label, .value = red.init };
		inputs[1] = { .label = mid, .value = mid_sum[i] };
	}
	vec_emit(&b, { .tag = ir::InstTag.JMP, .data.ref = header.label, .ty = value_interner::REF_NORETURN });
	// The VPH group: splats then the jump into the vector loop.
	List{ir::Ref} vph_code;
	vph_code.init(mem);
	defer vph_code.free();
	foreach (splat : outside_splats) vph_code.push(splat);
	vph_code.push(editor.append({ .tag = ir::InstTag.JMP, .data.ref = vh, .ty = value_interner::REF_NORETURN }));
	List{ir::Ref} rebuilt;
	rebuilt.init(mem);
	foreach (i, ref : *group)
	{
		if ((sz)i == vph_jump_slot)
		{
			foreach (code : vph_code) rebuilt.push(code);
			continue;
		}
		rebuilt.push(ref);
	}
	group.free();
	*group = rebuilt;
	// The original loop now enters from SPH.
	ir::PhiInput[] iv_phi = editor.insts.entries[(sz)plan.iv.phi].data.phi;
	foreach (&input : iv_phi) if (input.label == pre_label) { input.label = sph; input.value = siv; }
	foreach (i, red : plan.reductions)
	{
		ir::PhiInput[] inputs = editor.insts.entries[(sz)red.phi].data.phi;
		foreach (&input : inputs) if (input.label == pre_label) { input.label = sph; input.value = sred[i]; }
	}
}
