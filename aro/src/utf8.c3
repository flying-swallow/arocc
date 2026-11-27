// Shared UTF-8 sequence inspection, validation, decoding and encoding.
module aro::utf8;

<* Number of bytes in the leading-byte pattern for a UTF-8 sequence. *>
fn uint sequence_length(char b)
{
	switch
	{
		case b < 0x80: return 1;
		case (b & 0xE0) == 0xC0: return 2;
		case (b & 0xF0) == 0xE0: return 3;
		case (b & 0xF8) == 0xF0: return 4;
		default: return 0;
	}
}

<*
 Decode one UTF-8 sequence of length `len`. Returns false for malformed,
 overlong, surrogate or out-of-range sequences. The caller must ensure `len`
 bytes are readable from `s` and that `len` matches the leading byte.
*>
fn bool decode(char* s, uint len, uint* out)
{
	if (len == 0 || len > 4) return false;
	for (uint k = 1; k < len; k++)
	{
		if ((s[k] & 0xC0) != 0x80) return false;
	}
	uint cp;
	switch (len)
	{
		case 1:
			if (s[0] >= 0x80) return false;
			cp = s[0];
		case 2:
			if (s[0] < 0xC0 || s[0] > 0xDF) return false;
			cp = (uint)(s[0] & 0x1F) << 6 | (s[1] & 0x3F);
			if (cp < 0x80) return false;
		case 3:
			if (s[0] < 0xE0 || s[0] > 0xEF) return false;
			cp = (uint)(s[0] & 0x0F) << 12 | (uint)(s[1] & 0x3F) << 6 | (s[2] & 0x3F);
			if (cp < 0x800) return false;
			if (cp >= 0xD800 && cp <= 0xDFFF) return false;
		case 4:
			if (s[0] < 0xF0 || s[0] > 0xF7) return false;
			cp = (uint)(s[0] & 0x07) << 18 | (uint)(s[1] & 0x3F) << 12 | (uint)(s[2] & 0x3F) << 6 | (s[3] & 0x3F);
			if (cp < 0x10000) return false;
			if (cp > 0x10FFFF) return false;
		default:
			return false;
	}
	*out = cp;
	return true;
}

<*
 Zig `std.unicode.utf8ValidateSlice`: every sequence is complete, with no
 stray continuation bytes, overlong encodings, surrogate halves or values
 above U+10FFFF.
*>
fn bool validate(String s)
{
	usz i = 0;
	while (i < s.len)
	{
		uint len = sequence_length(s[i]);
		if (len == 0 || (usz)len > s.len - i) return false;
		uint cp;
		if (!decode(&s[i], len, &cp)) return false;
		i += len;
	}
	return true;
}

<*
 Decode one codepoint from already validated UTF-8 at `*i` and advance.
 @require *i < s.len
*>
fn uint decode_next(String s, sz* i)
{
	if (*i >= s.len) unreachable("decode_next requires a codepoint");
	uint len = sequence_length(s[*i]);
	if (len == 0 || (usz)len > s.len - (usz)*i) unreachable("decode_next requires valid UTF-8");
	uint cp;
	if (!decode(&s[*i], len, &cp)) unreachable("decode_next requires valid UTF-8");
	*i += len;
	return cp;
}

<* Zig `std.unicode.utf8Encode` for a codepoint <= 0x10FFFF (no surrogate check). *>
fn sz encode(uint c, char[4]* out)
{
	if (c < 0x80)
	{
		(*out)[0] = (char)c;
		return 1;
	}
	if (c < 0x800)
	{
		(*out)[0] = (char)(0xC0 | (c >> 6));
		(*out)[1] = (char)(0x80 | (c & 0x3F));
		return 2;
	}
	if (c < 0x10000)
	{
		(*out)[0] = (char)(0xE0 | (c >> 12));
		(*out)[1] = (char)(0x80 | ((c >> 6) & 0x3F));
		(*out)[2] = (char)(0x80 | (c & 0x3F));
		return 3;
	}
	(*out)[0] = (char)(0xF0 | (c >> 18));
	(*out)[1] = (char)(0x80 | ((c >> 12) & 0x3F));
	(*out)[2] = (char)(0x80 | ((c >> 6) & 0x3F));
	(*out)[3] = (char)(0x80 | (c & 0x3F));
	return 4;
}
