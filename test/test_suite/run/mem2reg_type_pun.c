// #kind: run
// #exit: 0

static float expected_float(int bits)
{
	float value;
	__builtin_memcpy(&value, &bits, sizeof value);
	return value;
}

static float union_pun(int bits)
{
	union IntFloat { int i; float f; } value;
	value.i = bits;
	return value.f;
}

static float pointer_pun(int bits)
{
	int value = bits;
	return *(float *)&value;
}

int main(void)
{
	int bits[] = { 0x3f800000, 0x40000000 };
	for (int i = 0; i < 2; i++) {
		float expected = expected_float(bits[i]);
		if (union_pun(bits[i]) != expected) return 1;
		if (pointer_pun(bits[i]) != expected) return 2;
	}
	return 0;
}
