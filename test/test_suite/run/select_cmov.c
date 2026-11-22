// #kind: run
// #exit: 0
int main(void)
{
	volatile int choose = 1;
	volatile int int_yes = 17;
	volatile int int_no = 29;
	volatile int int_expected;
	if (choose) int_expected = int_yes; else int_expected = int_no;
	int int_selected = choose ? int_yes : int_no;
	if (int_selected != int_expected) return 1;

	volatile char char_yes = 'Y';
	volatile char char_no = 'N';
	volatile char char_expected;
	if (choose) char_expected = char_yes; else char_expected = char_no;
	char char_selected = choose ? char_yes : char_no;
	if (char_selected != char_expected) return 2;

	volatile long long_yes = 0x123456789L;
	volatile long long_no = -7L;
	volatile long long_expected;
	if (choose) long_expected = long_yes; else long_expected = long_no;
	long long_selected = choose ? long_yes : long_no;
	if (long_selected != long_expected) return 3;

	int pointed = 91;
	volatile int *pointer_yes = &pointed;
	volatile int *pointer_no = 0;
	volatile int *pointer_expected;
	if (choose) pointer_expected = pointer_yes; else pointer_expected = pointer_no;
	volatile int *pointer_selected = choose ? pointer_yes : pointer_no;
	if (pointer_selected != pointer_expected) return 4;

	volatile __int128 wide_yes = (((__int128)1) << 100) + 3;
	volatile __int128 wide_no = -11;
	volatile __int128 wide_expected;
	if (choose) wide_expected = wide_yes; else wide_expected = wide_no;
	__int128 wide_selected = choose ? wide_yes : wide_no;
	if (wide_selected != wide_expected) return 5;

	volatile int null_condition = 0;
	volatile int *null_selected = null_condition ? pointer_yes : 0;
	volatile int *null_expected;
	if (null_condition) null_expected = pointer_yes; else null_expected = 0;
	if (null_selected != null_expected) return 6;

	// This source-level select reaches Lowering.select once the pending
	// if-conversion pass turns suitable diamonds into SELECT instructions.
	volatile short short_yes = -1234;
	volatile short short_no = 2345;
	volatile short short_expected;
	if (choose) short_expected = short_yes; else short_expected = short_no;
	short short_selected = choose ? short_yes : short_no;
	if (short_selected != short_expected) return 7;

	volatile _Bool bool_yes = 1;
	volatile _Bool bool_no = 0;
	volatile _Bool bool_expected;
	if (choose) bool_expected = bool_yes; else bool_expected = bool_no;
	_Bool bool_selected = choose ? bool_yes : bool_no;
	if (bool_selected != bool_expected) return 8;

	volatile float float_yes = 3.25f;
	volatile float float_no = -7.5f;
	volatile float float_expected;
	if (choose) float_expected = float_yes; else float_expected = float_no;
	float float_selected = choose ? float_yes : float_no;
	if (float_selected != float_expected) return 9;

	volatile double double_yes = 3.25;
	volatile double double_no = -7.5;
	volatile double double_expected;
	if (choose) double_expected = double_yes; else double_expected = double_no;
	double double_selected = choose ? double_yes : double_no;
	if (double_selected != double_expected) return 10;

	// Equality alone cannot distinguish signed zero; check its reciprocal.
	volatile double negative_zero = -0.0;
	volatile double positive_zero = 0.0;
	volatile double zero_expected;
	if (choose) zero_expected = negative_zero; else zero_expected = positive_zero;
	double zero_selected = choose ? negative_zero : positive_zero;
	if (zero_selected != zero_expected || 1.0 / zero_selected >= 0) return 11;

	volatile long double long_double_yes = 3.25L;
	volatile long double long_double_no = -7.5L;
	volatile long double long_double_expected;
	if (choose) long_double_expected = long_double_yes; else long_double_expected = long_double_no;
	long double long_double_selected = choose ? long_double_yes : long_double_no;
	if (long_double_selected != long_double_expected) return 12;

	volatile long double long_negative_zero = -0.0L;
	volatile long double long_positive_zero = 0.0L;
	volatile long double long_zero_expected;
	if (choose) long_zero_expected = long_negative_zero; else long_zero_expected = long_positive_zero;
	long double long_zero_selected = choose ? long_negative_zero : long_positive_zero;
	if (long_zero_selected != long_zero_expected || 1.0L / long_zero_selected >= 0) return 13;

	struct MemberOwner { int member; } member_left = { 41 }, member_right = { 53 };
	int *member_yes = &member_left.member;
	int *member_no = &member_right.member;
	int *member_expected;
	if (choose) member_expected = member_yes; else member_expected = member_no;
	int *member_selected = choose ? member_yes : member_no;
	if (member_selected != member_expected) return 14;
	return 0;
}
