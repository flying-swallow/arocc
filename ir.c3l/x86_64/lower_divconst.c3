module aro::backend::x86_64;
import aro::primitive_value, aro::backend::ir;

struct UnsignedMagic
{
	bool valid;
	ulong multiplier;
	ushort shift;
	bool add;
}

struct SignedMagic
{
	bool valid;
	ulong magnitude;
	ulong multiplier;
	ushort shift;
	bool add;
	bool negative;
	bool signed_correction;
}

<* Compute the unsigned division magic number from Hacker's Delight 10-2.
   All arithmetic is widened so the 64-bit case can represent 2^127. *>
fn bool unsigned_div_magic(uint width, ulong divisor, ulong* magic,
	uint* shift, bool* add)
{
	if (divisor == 0 || divisor == 1 || width == 0 || width > 64) return false;
	uint128 one = 1;
	uint128 n = one << width;
	uint128 d = divisor;
	uint128 nc = n - 1 - ((n - d) % d);
	uint p = width - 1;
	uint128 q1 = (one << p) / nc;
	uint128 r1 = (one << p) - q1 * nc;
	uint128 q2 = ((one << p) - 1) / d;
	uint128 r2 = ((one << p) - 1) - q2 * d;
	uint128 delta;
	while (true)
	{
		p++;
		q1 *= 2;
		r1 *= 2;
		if (r1 >= nc) { q1++; r1 -= nc; }
		q2 *= 2;
		r2 = r2 * 2 + 1;
		if (r2 >= d) { q2++; r2 -= d; }
		// Match the unsigned do/while recurrence: update first, then test.
		delta = d - 1 - r2;
		if (q1 > delta || (q1 == delta && r1 != 0)) break;
		if (p >= width * 2) return false;
	}
	uint128 m = q2 + 1;
	// The add-marker form represents an extra 2^width multiplier term with
	// the correction step in divide_constant.
	if (m == n || m >= n * 2) return false;
	*magic = (ulong)(m >= n ? m - n : m);
	*add = m >= n;
	*shift = p - width - (*add ? 1 : 0);
	return true;
}

<* Pure unsigned division magic description for a divisor of the given width. *>
fn UnsignedMagic magic_unsigned(ulong d, ushort w)
{
	UnsignedMagic result;
	ulong mask = w == 64 ? ulong::max : (w > 0 && w < 64 ? (((ulong)1 << w) - 1) : 0);
	d &= mask;
	if (w != 8 && w != 16 && w != 32 && w != 64) return result;
	if (d <= 1) return result;
	uint shift = 0;
	result.valid = unsigned_div_magic(w, d, &result.multiplier, &shift, &result.add);
	result.shift = (ushort)shift;
	return result;
}

<* Test-only classic signed division magic (Hacker's Delight 10-1). The negative flag
   records the divisor sign; signed_correction indicates whether the quotient
   needs the dividend adjustment for this multiplier's sign. *>
fn SignedMagic magic_signed(long d, ushort w)
{
	SignedMagic result;
	if (w != 8 && w != 16 && w != 32 && w != 64) return result;
	ulong mask = w == 64 ? ulong::max : (((ulong)1 << w) - 1);
	ulong bits = (ulong)d & mask;
	if (bits == 0) return result;
	result.negative = ((bits >> (w - 1)) & 1) != 0;
	result.magnitude = result.negative ? ((0 - bits) & mask) : bits;
	if (result.magnitude <= 1 || (result.magnitude & (result.magnitude - 1)) == 0)
	{
		result.valid = true;
		return result;
	}
	// Hacker's Delight 10-1 signed magic. Keep the multiplier as its width-bit
	// representation; callers use signed_correction when its sign differs from
	// the divisor's sign.
	uint128 one = 1;
	uint128 n = one << w;
	uint128 signed_min = one << (w - 1);
	uint128 t = signed_min + (result.negative ? (uint128)1 : (uint128)0);
	uint128 dmag = result.magnitude;
	uint128 anc = t - 1 - (t % dmag);
	uint p = w - 1;
	uint128 q1 = signed_min / anc;
	uint128 r1 = signed_min - q1 * anc;
	uint128 q2 = signed_min / dmag;
	uint128 r2 = signed_min - q2 * dmag;
	uint128 delta;
	// The Hacker's Delight recurrence is a do/while: perform at least one
	// doubling before checking whether the candidate multiplier is sufficient.
	while (true)
	{
		p++;
		q1 *= 2;
		r1 *= 2;
		if (r1 >= anc) { q1++; r1 -= anc; }
		q2 *= 2;
		r2 *= 2;
		if (r2 >= dmag) { q2++; r2 -= dmag; }
		delta = dmag - r2;
		if (q1 > delta || (q1 == delta && r1 != 0)) break;
		// For the supported signed widths, magic shifts are bounded by width.
		if (p >= (uint)w * 2) return result;
	}
	uint128 m = q2 + 1;
	if (result.negative) m = (n - m) % n;
	if (p < w || p - w >= w) return result;
	result.valid = true;
	result.multiplier = (ulong)m;
	result.shift = (ushort)(p - w);
	bool multiplier_negative = ((result.multiplier >> (w - 1)) & 1) != 0;
	result.signed_correction = multiplier_negative != result.negative;
	return result;
}

<* Try lowering division or remainder by a nonzero integer constant.
   Return false when this operation should use the ordinary DIV path. *>
fn bool? Lowering.divide_constant(&self, ir::Ref ref, bool signed, bool remainder)
{
	ir::Inst inst = self.inst(ref);
	ir::Inst rhs = self.inst(inst.data.bin.rhs);
	primitive_value::PrimitiveValue type = self.ir.interner.get(inst.ty);
	if (type.tag != primitive_value::PrimitiveType.INT_TY) return false;
	ushort width = type.ty_bits;
	if (width != 8 && width != 16 && width != 32 && width != 64) return false;
	if (rhs.tag != CONSTANT) return false;
	primitive_value::PrimitiveValue value = self.ir.interner.get(rhs.data.constant);
	if ((value.tag != primitive_value::PrimitiveType.INT_POSITIVE &&
		value.tag != primitive_value::PrimitiveType.INT_NEGATIVE) || !value.int_fits_64()) return false;
	ulong divisor = value.int_low_u64();
	ulong width_mask = width == 64 ? ulong::max : (((ulong)1 << width) - 1);
	divisor &= width_mask;
	if (divisor == 0) return false;
	bool divisor_negative = signed && ((divisor >> (width - 1)) & 1) != 0;
	if (divisor_negative) divisor = (0 - divisor) & width_mask;
	bool power_of_two = (divisor & (divisor - 1)) == 0;
	uint trailing = 0;
	while (((divisor >> trailing) & 1) == 0) trailing++;
	ulong magic = 0;
	uint post_shift = 0;
	bool add = false;
	if (!power_of_two && !unsigned_div_magic(width, divisor, &magic, &post_shift, &add)) return false;
	// Signed division uses the unsigned magic path on absolute magnitudes, then
	// restores the quotient or remainder sign below.
	if (signed)
	{
		self.load_extended(inst.data.bin.lhs, RAX, true)!;
	}
	else
	{
		self.load(inst.data.bin.lhs, RAX)!;
	}
	uint operation_width = width < 32 ? 32 : width;
	Register ax = Register.RAX.to_bits((ushort)operation_width);
	Register cx = Register.RCX.to_bits((ushort)operation_width);
	Register dx = Register.RDX.to_bits((ushort)operation_width);
	Register r8 = Register.R8.to_bits((ushort)operation_width);
	Register r11 = Register.R11.to_bits((ushort)operation_width);
	Register r9 = Register.R9.to_bits((ushort)operation_width);
	if (width < 32 && !signed)
	{
		self.emit(MOVZX, reg_op(ax), reg_op(Register.RAX.to_bits(width)));
	}
	if (signed)
	{
		self.emit(MOV, reg_op(r11), reg_op(ax));
		self.emit(SAR, reg_op(r11), imm_op((long)(operation_width - 1)));
		self.emit(MOV, reg_op(r9), reg_op(r11));
		self.emit(MOV, reg_op(r8), reg_op(r11));
		if (divisor_negative) self.emit(NOT, reg_op(r8));
		self.emit(XOR, reg_op(ax), reg_op(r11));
		self.emit(SUB, reg_op(ax), reg_op(r11));
	}
	if (power_of_two)
	{
		// Divisors +1 and -1 use this shift-by-zero path; the later sign
		// fixup preserves wrapping machine semantics without a special case.
		if (remainder)
		{
			self.emit(MOV, reg_op(cx), imm_op((long)(divisor - 1)));
			self.emit(AND, reg_op(ax), reg_op(cx));
		}
		else
		{
			self.emit(SHR, reg_op(ax), imm_op((long)trailing));
		}
		if (signed)
		{
			self.emit(MOV, reg_op(dx), reg_op(ax));
			self.emit(XOR, reg_op(dx), reg_op(remainder ? r9 : r8));
			self.emit(SUB, reg_op(dx), reg_op(remainder ? r9 : r8));
			self.emit(MOV, reg_op(ax), reg_op(dx));
		}
		self.store(ref, RAX)!;
		return true;
	}

	// Keep the magnitude for the add-marker correction and remainder recovery.
	self.emit(MOV, reg_op(r11), reg_op(ax));
	self.emit(MOV, reg_op(cx), imm_op((long)magic));
	if (width < 32)
	{
		self.emit(MUL, reg_op(cx));
		self.emit(SHR, reg_op(EAX), imm_op((long)width));
	}
	else if (width == 32)
	{
		self.emit(MUL, reg_op(ECX));
		self.emit(MOV, reg_op(EAX), reg_op(EDX));
	}
	else
	{
		self.emit(MUL, reg_op(RCX));
		self.emit(MOV, reg_op(RAX), reg_op(RDX));
	}
	// The high half is no longer needed; preserve the dividend there for a
	// possible remainder reconstruction.
	self.emit(MOV, reg_op(dx), reg_op(r11));
	if (add)
	{
		// Apply NPQ directly, including for even divisors; LLVM's optional
		// pre-shift is an optimization this lowering intentionally skips.
		self.emit(SUB, reg_op(r11), reg_op(ax));
		self.emit(SHR, reg_op(r11), imm_op(1));
		self.emit(ADD, reg_op(ax), reg_op(r11));
	}
	if (post_shift != 0) self.emit(SHR, reg_op(ax), imm_op((long)post_shift));
	if (remainder)
	{
		self.emit(MOV, reg_op(cx), imm_op((long)divisor));
		self.emit(IMUL, reg_op(ax), reg_op(cx));
		self.emit(SUB, reg_op(dx), reg_op(ax));
		self.emit(MOV, reg_op(ax), reg_op(dx));
	}
	if (signed)
	{
		self.emit(MOV, reg_op(dx), reg_op(ax));
		self.emit(XOR, reg_op(dx), reg_op(remainder ? r9 : r8));
		self.emit(SUB, reg_op(dx), reg_op(remainder ? r9 : r8));
		self.emit(MOV, reg_op(ax), reg_op(dx));
	}
	self.store(ref, RAX)!;
	return true;
}
