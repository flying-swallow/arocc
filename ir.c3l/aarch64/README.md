# ARM64 macOS backend

This backend follows the existing `x86_64` backend's structure:

| Component | Responsibility |
| --- | --- |
| `bits.c3` | Registers, conditions, mnemonics, operands and addressing modes |
| `lower.c3` | Per-function state, stack layout and instruction selection |
| `lower_operand.c3` | Constants, addresses, loads, stores and width normalization |
| `lower_branch.c3` | Comparisons, conditional branches and switches |
| `lower_phi.c3` | Incoming-edge PHI copies and jumps |
| `abi.c3` | Calls, result registers and stack adjustments |
| `emit_text.c3` | Print instruction rows, Mach-O directives and serialized globals |

As in the original stack-based x86 lowering, values occupy frame slots and
operations use scratch registers. `Lowering.emit` creates typed `Line` rows;
only the text emitter formats machine instructions. Directives have raw rows.
This gives a future integrated ARM64 encoder the same instruction stream as
the text emitter. There is no ARM64 instruction encoder or Mach-O writer yet.

Scratch registers are x9-x17 and v16-v17; x18 is reserved by Darwin. Frames
preserve x29/x30 and keep SP aligned to 16 bytes. Each PHI has a separate
incoming-copy slot so cyclic parallel copies and computed gotos remain safe.

## Darwin C ABI

`frontend/c/codegen_darwin.c3` classifies C arguments before instruction
selection. `ArgData` supplies explicit register or byte-offset stack locations.
The existing `SSE_REGISTER` location kind denotes the target's FP register bank
(v0-v7 here); its historical name remains for x86 compatibility.

Darwin calls carry those locations and a `DarwinAggregate` result descriptor.
For an aggregate result, argument zero is the caller's result storage. Small
results and HFAs are received from x0-x1 or s0-s3/d0-d3 and copied to that
storage; larger non-HFAs pass the storage in x8. Aggregate-returning function
IR returns an address, and the descriptor tells lowering which result
registers to fill. The pointer operands keep result memory visible to scalar
optimization. Signature-changing IPO, inlining and tail-call rewriting are
currently disabled for Darwin functions; scalar and loop passes still run.

Named scalar stack arguments are naturally packed. HFAs use contiguous FP
registers or contiguous naturally aligned stack members. Anonymous arguments
start on eight-byte boundaries, and Darwin `va_list` is a pointer advanced by
the frontend's builtin lowering. Fixed-signature scalar runtime helpers such
as memcpy/memset use the backend's ordinary argument placement.

The implementation was checked against the user's LLVM source checkout at
revision `f7a944f54088`, particularly:

- `llvm/lib/Target/AArch64/AArch64CallingConvention.td`
- `llvm/lib/Target/AArch64/AArch64CallingConvention.cpp`
- `clang/lib/CodeGen/Targets/AArch64.cpp`

LLVM is a reference, not a build dependency. Native integration tests compile
callers and callees with Aro and Apple Clang in both directions.

## Current boundary

Supported: ARM64 macOS C, integer/pointer operations through 64 bits, scalar
float/double (including macOS long double), structs/unions and HFAs, variadic
functions, globals and relocations, VLAs, branches and switches. Apple tools
selected by xcrun assemble and link output using the selected SDK.

Deferred: ARM32, other ARM64 operating systems, C3 frontend integration, NEON
and vector ABI, GNU inline assembly, atomics, TLS, 128-bit arithmetic, debug
information, stack alignment above 16 bytes, register allocation, integrated
assembly and linking. Unsupported operations report lowering errors.

Some Xcode SDK headers still fail in the C frontend on availability and
nullability annotations. Backend ABI tests use direct libc declarations and
the bundled stdarg header; they do not establish full SDK-header compatibility.
