// AVX-512 (EVEX) instruction forms. The rows are generated from Intel XED
// (AVX512F and the Skylake-X sets: CD/BW/DQ/VL) into encoding_table_evex.c3 by
// //tools/gen_x86_encodings --evex=...; this file holds the hand-written row
// shape they use.
//
// Data only for now: no lowering emits EVEX instructions and encode.c3 only
// encodes the legacy ENCODINGS rows. An EVEX encoder builds the 62 P0 P1 P2
// prefix from `map`, `prefix`, `w` and `vl`, and scales 8-bit displacements by
// `EvexEntry.disp8_n`.
//
// Unlike the legacy table, one row covers every masking/broadcast/rounding
// variant of a form: those are `flags`, not separate rows. The writemask
// `{k}` is not an operand; a mask register that is a real operand (compare
// destination, kmov-style sources) is `EvexOp.K`.
module aro::backend::x86_64;

<* EVEX.mmm opcode map. *>
enum EvexMap : char (char mmm)
{
	MAP0F { 1 },
	MAP0F38 { 2 },
	MAP0F3A { 3 },
	MAP5 { 5 },
	MAP6 { 6 },
}

<* EVEX.pp implied SIMD prefix; the ordinal is the encoded value. *>
enum EvexPrefix : char
{
	NONE,
	P66,
	PF3,
	PF2,
}

<* EVEX.W; WIG forms accept either value. *>
enum EvexW : char
{
	W0,
	W1,
	WIG,
}

<* EVEX.L'L vector length. LIG: scalar forms, where L'L is ignored (or holds the rounding mode). *>
enum VectorLength : char (ushort bits)
{
	L128 { 128 },
	L256 { 256 },
	L512 { 512 },
	LIG { 128 },
}

<* Intel SDM tuple type (XED NELEM_*): selects N for the compressed disp8*N displacement. *>
enum EvexTuple : char
{
	NONE,
	FULL,
	HALF,
	FULL_MEM,
	HALF_MEM,
	QUARTER_MEM,
	EIGHTH_MEM,
	TUPLE1_SCALAR,
	TUPLE2,
	TUPLE4,
	TUPLE8,
	MEM128,
	MOVDDUP,
}

<* Which EVEX decorations a form accepts. *>
bitstruct EvexFlags : char
{
	<* An opmask `{k1}` may be given. *>
	bool mask : 0;
	<* Zeroing-masking `{z}` may be given. *>
	bool zeroing : 1;
	<* The memory operand may be an embedded broadcast `{1toN}` of `elem_bits`. *>
	bool bcst : 2;
	<* The register form accepts embedded rounding `{er}`. *>
	bool er : 3;
	<* The register form accepts suppress-all-exceptions `{sae}`. *>
	bool sae : 4;
	<* The opmask is required and must not be k0 (gather/scatter). *>
	bool mask_required : 5;
}

<* One EVEX instruction form. *>
struct EvexEntry
{
	EvexMnemonic mnemonic;
	<* Operand sites in order: R = ModRM.reg, V = EVEX.vvvv, M = ModRM.rm, I = imm8. *>
	EvexOpEn op_en;
	EvexOp[4] ops;
	EvexMap map;
	EvexPrefix prefix;
	char opcode;
	<* ModRM.reg opcode extension, or -1 when ModRM.reg holds an operand. *>
	ichar reg_ext;
	EvexW w;
	VectorLength vl;
	EvexTuple tuple;
	<* Element size in bits (broadcast and disp8*N); 0 for forms without memory. *>
	ushort elem_bits;
	EvexFlags flags;
}

<* N of the compressed disp8*N displacement for this form's memory operand (Intel SDM 2.7.5). *>
fn ushort EvexEntry.disp8_n(&self, bool broadcast)
{
	ushort vl = self.vl.bits / 8;
	ushort e = self.elem_bits / 8;
	switch (self.tuple)
	{
		case NONE: return 1;
		case FULL: return broadcast ? e : vl;
		case HALF: return broadcast ? e : vl / 2;
		case FULL_MEM: return vl;
		case HALF_MEM: return vl / 2;
		case QUARTER_MEM: return vl / 4;
		case EIGHTH_MEM: return vl / 8;
		case TUPLE1_SCALAR: return e;
		case TUPLE2: return 2 * e;
		case TUPLE4: return 4 * e;
		case TUPLE8: return 8 * e;
		case MEM128: return 16;
		case MOVDDUP: return vl == 16 ? 8 : vl;
	}
}
