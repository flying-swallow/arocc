---
title: 'C3 migration 27: port ELF object serialization without Zig stdlib'
state: waiting
depends_on:
- c3-migration-26-port-experimental-ir-and-ast-to-ir-lowering
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
---

Add src/c3/backend/object.c3 and elf.c3 with test/c3/elf_tests.c3. Translate backend/Object.zig dispatch and Object/Elf.zig section buffers, symbol tables/linkage, unnamed names, relocation records and finish serialization. Replace std.elf structures/constants and std.Target.toElfMachine with explicit fixed-width encoders and target mappings, retaining the actual reference's supported ELF class/endianness and relocation limits. Never serialize host struct layout/padding. Keep unsupported formats/targets explicit; converting a reference unreachable/panic to a structured unsupported error is acceptable only when documented and tested, not counted as newly supported output. Wire Ir renderer/object interfaces without implementing missing machine lowering.
Run bazel test //test/c3:elf_tests. Construct objects directly with text/data/custom sections, local/global/external/anonymous symbols, alignment and relocations; compare decoded section/symbol/relocation semantics with reference objects (map iteration may affect byte order). Verify encoded offsets, lengths, table links, machine/class/endian and short-write errors. Use a small independent test decoder or a declared platform readelf/llvm-readobj test dependency; do not silently skip validation if a tool is absent. Preserve existing object support boundaries rather than expanding backend scope

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).


## Parallel agent breakdown

Rules: [PARALLEL.md](PARALLEL.md). Each agent owns only the files listed for it. Only the integrator edits `project.json` and `BUILD.bazel`.

**Stage 0: contract (1 agent, serial).** Define fixed-width little/big-endian encoders and the explicit ELF constants and machine mapping table.

**Stage 1: parallel agents (start together after stage 0 merges).**
- **27.1 `elf-writer`**: owns `src/c3/backend/elf.c3`. Section buffers, symbol tables/linkage, unnamed names, relocations, finish serialization.
- **27.2 `object`**: owns `src/c3/backend/object.c3`. Object dispatch, explicit unsupported formats, renderer wiring.
- **27.3 `decoder`**: owns `test/c3/elf_decoder.c3`. Small independent decoder for sections/symbols/relocations.
- **27.4 `refs`**: owns `test/c3/data/elf/*`. Reference objects from the pinned Zig build.

**Stage 2: integrator (1 agent, serial).** Write `test/c3/elf_tests.c3` (semantic comparison plus short-write errors) and register the target.
