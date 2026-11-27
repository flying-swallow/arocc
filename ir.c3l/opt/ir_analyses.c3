// Analyses shared between consecutive function passes, and a module-level
// declaration name lookup shared while the declaration list is stable.
module aro::backend::ir_opt;
import aro::backend::ir, std::collections::list, std::collections::map;

<* Lazily built per-function analyses. A pass that edits the function must
   either not touch the cache afterwards or call `invalidate` first; the pass
   runner invalidates after every pass that reports a change. The cache owns
   everything it hands out, so passes must not free the returned analyses. *>
struct FunctionAnalyses
{
	Allocator allocator;
	ir::Decl* decl;
	Cfg cfg;
	Uses uses;
	LoopInfo loops;
	bool has_cfg;
	<* The function was edited since `cfg` was built: revalidate before use. *>
	bool cfg_dirty;
	bool has_frontiers;
	bool has_uses;
	bool has_loops;
}

fn void FunctionAnalyses.init(&self, ir::Decl* decl, Allocator allocator)
{
	*self = { .allocator = allocator, .decl = decl };
}

fn void FunctionAnalyses.invalidate(&self)
{
	if (self.has_loops) self.loops.free();
	if (self.has_cfg) self.cfg.free();
	if (self.has_uses) self.uses.free();
	self.has_cfg = false;
	self.cfg_dirty = false;
	self.has_frontiers = false;
	self.has_uses = false;
	self.has_loops = false;
}

fn void FunctionAnalyses.free(&self) => self.invalidate();

<* Record that the function was edited. Def-use lists are dropped (rebuilding
   the CSR is two linear passes); the CFG is kept and revalidated on the next
   `get_cfg`, which keeps dominators, frontiers and loops when the edit left
   every block and edge in place (the common case for scalar rewrites). *>
fn void FunctionAnalyses.mark_dirty(&self)
{
	if (self.has_uses) self.uses.free();
	self.has_uses = false;
	if (self.has_cfg) self.cfg_dirty = true;
}

<* Control-flow graph, optionally with dominators and dominance frontiers. *>
fn Cfg* FunctionAnalyses.get_cfg(&self, bool dominators = false, bool frontiers = false)
{
	if (self.has_cfg && self.cfg_dirty)
	{
		self.cfg_dirty = false;
		if (!self.cfg.revalidate())
		{
			if (self.has_loops) self.loops.free();
			self.cfg.free();
			self.has_cfg = false;
			self.has_frontiers = false;
			self.has_loops = false;
		}
	}
	if (!self.has_cfg)
	{
		self.cfg = build_cfg(self.decl, self.allocator);
		self.has_cfg = true;
	}
	if ((dominators || frontiers) && !self.cfg.idom.len && self.cfg.blocks.len) self.cfg.compute_dominators();
	if (frontiers && !self.has_frontiers && self.cfg.blocks.len)
	{
		self.cfg.compute_frontiers();
		self.has_frontiers = true;
	}
	return &self.cfg;
}

fn Uses* FunctionAnalyses.get_uses(&self)
{
	if (!self.has_uses)
	{
		self.uses = compute_uses(self.decl, self.allocator);
		self.has_uses = true;
	}
	return &self.uses;
}

<* Natural loops; builds the CFG and dominators on demand. *>
fn LoopInfo* FunctionAnalyses.get_loops(&self)
{
	// Revalidate first: a shape change drops the loops along with the CFG.
	Cfg* cfg = self.get_cfg(dominators: true);
	if (!self.has_loops)
	{
		self.loops = compute_loops(cfg, self.allocator);
		self.has_loops = true;
	}
	return &self.loops;
}

<* Pick the shared cache when the caller passed one, else initialize `owned`
   (which the caller frees; freeing a zeroed `owned` is a no-op). *>
fn FunctionAnalyses* function_analyses(FunctionAnalyses* shared, FunctionAnalyses* owned, ir::Decl* decl)
{
	if (shared)
	{
		assert(shared.decl == decl, "analysis cache belongs to another function");
		return shared;
	}
	owned.init(decl, mem);
	return owned;
}

fn bool uint_lists_equal(list::List{uint}* a, list::List{uint}* b)
{
	if (a.len() != b.len()) return false;
	for (sz i = 0; i < a.len(); i++) if (a.entries[i] != b.entries[i]) return false;
	return true;
}

<* Debug check (run under `--verify`): every cached analysis must equal a fresh
   rebuild. A mismatch means a pass edited the function but reported no change. *>
fn bool FunctionAnalyses.matches_fresh(&self)
{
	@pool()
	{
		if (self.has_cfg && self.cfg_dirty) self.get_cfg();
		if (self.has_cfg)
		{
			Cfg fresh = build_cfg(self.decl, self.allocator);
			defer fresh.free();
			Cfg* cached = &self.cfg;
			if (fresh.blocks.len != cached.blocks.len || fresh.rpo != cached.rpo ||
				fresh.reachable != cached.reachable || fresh.block_of_ref != cached.block_of_ref) return false;
			foreach (i, &block : fresh.blocks)
			{
				CfgBlock* old = &cached.blocks[i];
				if (block.label != old.label || block.start != old.start || block.end != old.end ||
					!uint_lists_equal(&block.preds, &old.preds) || !uint_lists_equal(&block.succs, &old.succs)) return false;
			}
			if (cached.idom.len && fresh.blocks.len)
			{
				fresh.compute_dominators();
				if (fresh.idom != cached.idom || fresh.dom_pre != cached.dom_pre || fresh.dom_post != cached.dom_post) return false;
			}
			if (self.has_frontiers && fresh.blocks.len)
			{
				fresh.compute_frontiers();
				foreach (i, &block : fresh.blocks)
				{
					if (!uint_lists_equal(&block.frontier, &cached.blocks[i].frontier)) return false;
				}
			}
			if (self.has_loops)
			{
				if (!fresh.idom.len && fresh.blocks.len) fresh.compute_dominators();
				LoopInfo loops = compute_loops(&fresh, self.allocator);
				defer loops.free();
				if (loops.loops.len() != self.loops.loops.len()) return false;
				foreach (i, &loop : loops.loops)
				{
					Loop* old_loop = &self.loops.loops.entries[i];
					if (loop.header != old_loop.header || loop.parent != old_loop.parent ||
						!uint_lists_equal(&loop.blocks, &old_loop.blocks) || !uint_lists_equal(&loop.exits, &old_loop.exits)) return false;
				}
			}
		}
		if (self.has_uses)
		{
			Uses fresh = compute_uses(self.decl, tmem);
			if (fresh.offsets != self.uses.offsets || fresh.flat != self.uses.flat) return false;
		}
		return true;
	};
}

<* Name -> declaration index snapshot for call-target lookups. Installed on
   `ir::Ir.decl_lookup` by `run` while only function passes run (they never add,
   remove or reorder declarations). Names are copied so compaction, which moves
   a decl's name into a fresh arena, cannot leave keys dangling. *>
struct DeclLookup
{
	HashMap{String, uint} first;
	HashMap{String, uint} last;
	DynamicArenaAllocator names;
}

fn void DeclLookup.init(&self, ir::Ir* graph)
{
	self.first.init(graph.allocator);
	self.last.init(graph.allocator);
	self.names.init(graph.allocator, 4096);
	foreach (i, decl : graph.decls)
	{
		if (!self.first.has_key(decl.name))
		{
			String name = decl.name.copy(&self.names);
			self.first.set(name, (uint)i);
			self.last.set(name, (uint)i);
		}
		else
		{
			self.last.set(decl.name, (uint)i);
		}
	}
}

fn void DeclLookup.free(&self)
{
	self.first.free();
	self.last.free();
	self.names.free();
}

<* First (or, with `last`, final) declaration named `name`; null when none. *>
fn ir::Decl* find_decl_by_name(ir::Ir* graph, String name, bool last = false)
{
	DeclLookup* lookup = (DeclLookup*)graph.decl_lookup;
	if (lookup)
	{
		uint? index = last ? lookup.last.get(name) : lookup.first.get(name);
		if (catch index) return null;
		return &graph.decls.entries[(sz)index];
	}
	if (last)
	{
		for (sz i = graph.decls.len(); i > 0; i--)
		{
			if (graph.decls.entries[i - 1].name == name) return &graph.decls.entries[i - 1];
		}
		return null;
	}
	foreach (i, decl : graph.decls)
	{
		if (decl.name == name) return &graph.decls.entries[(sz)i];
	}
	return null;
}
