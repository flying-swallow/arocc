// #kind: run
// #exit: 0
/* Struct and union values: copies at several sizes, value-producing
   expressions, nested records, unions, and padding-safe member checks. */
struct Small { int a, b; };
struct R12 { unsigned char data[12]; };
struct R24 { unsigned char data[24]; };
struct R80 { unsigned char data[80]; };
struct Inner { int left, right; };
struct Nested { struct Small small; struct Inner inner; };
struct Node { struct Nested nested; struct Node *next; };
struct Padded { char tag; long value; char tail; };
union Value { int i; unsigned long wide; unsigned char raw[16]; };

static union Value global_value = { .i = 73 };

int main(void)
{
	int failures = 0;

	struct Small small_source = { 3, 5 };
	struct Small small_init = small_source;
	struct Small small_copy = { 0, 0 };
	small_copy = small_init;
	struct Small *small_ptr = &small_copy;
	*small_ptr = small_source;
	small_copy = *small_ptr;
	failures += (sizeof small_copy == 8 && small_copy.a == 3 && small_copy.b == 5) ? 0 : 1;

	struct R12 r12_source = { { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 } };
	struct R12 r12_init = r12_source;
	struct R12 r12_copy;
	r12_copy = r12_init;
	int r12_ok = sizeof r12_copy == 12;
	for (int i = 0; i < 12; i++) r12_ok &= r12_copy.data[i] == i + 1;
	failures += r12_ok ? 0 : 2;

	struct R24 r24_source = { { 24, 23, 22, 21, 20, 19, 18, 17, 16, 15, 14, 13,
		12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1 } };
	struct R24 r24_init = r24_source;
	struct R24 r24_copy;
	r24_copy = r24_init;
	int r24_ok = sizeof r24_copy == 24;
	for (int i = 0; i < 24; i++) r24_ok &= r24_copy.data[i] == 24 - i;
	failures += r24_ok ? 0 : 4;

	struct R80 r80_source = { { 0 } };
	for (int i = 0; i < 80; i++) r80_source.data[i] = (unsigned char)(i * 3 + 1);
	struct R80 r80_init = r80_source;
	struct R80 r80_copy;
	r80_copy = r80_init;
	int r80_ok = sizeof r80_copy == 80;
	for (int i = 0; i < 80; i++) r80_ok &= r80_copy.data[i] == (unsigned char)(i * 3 + 1);
	failures += r80_ok ? 0 : 8;

	struct Small other = { 13, 17 };
	struct Small records[3] = { small_init, { 41, 43 }, (struct Small){ 47, 53 } };
	failures += (records[0].a == 3 && records[0].b == 5 &&
		records[1].a == 41 && records[1].b == 43 &&
		records[2].a == 47 && records[2].b == 53) ? 0 : 16;

	int take_source = 1;
	struct Small ternary_value = take_source ? small_source : other;
	int ternary_member = (take_source ? small_source : other).b;
	small_copy = take_source ? small_source : other;
	small_copy = take_source ? small_copy : other;
	int self_copy_member = (small_copy = small_copy).a;
	struct Small comma_value = (small_source.a = 7, small_source);
	int comma_member = (small_source.a++, other).b;
	small_copy = ({
		struct Small temporary = small_source;
		temporary.b += 2;
		temporary;
	});
	struct Small statement_value = ({
		struct Small temporary = small_source;
		temporary.b += 2;
		temporary;
	});
	int statement_member = ({
		struct Small temporary = other;
		temporary.a += 4;
		temporary;
	}).a;
	failures += (ternary_value.a == 3 && ternary_value.b == 5 && ternary_member == 5 &&
		self_copy_member == 3 && comma_value.a == 7 && comma_value.b == 5 &&
		small_copy.a == 8 && small_copy.b == 7 &&
		comma_member == 17 && statement_value.a == 8 && statement_value.b == 7 &&
		statement_member == 17) ? 0 : 32;

	struct Nested nested_source = { { 29, 31 }, { 37, 41 } };
	struct Inner inner_source = { 43, 47 };
	struct Outer { struct Inner in; int tag; } outer = { inner_source, 3 };
	struct Outer designated_outer = { .in = inner_source, .tag = 5 };
	int rvalue_nested_member = ({ outer; }).in.left;
	failures += (outer.in.left == 43 && outer.in.right == 47 && outer.tag == 3 &&
		designated_outer.in.left == 43 && designated_outer.in.right == 47 &&
		designated_outer.tag == 5 && rvalue_nested_member == 43) ? 0 : 512;
	struct Node node_source = { .nested = nested_source, .next = 0 };
	struct Node node_destination = { 0 };
	struct Node *source_ptr = &node_source;
	struct Node *destination_ptr = &node_destination;
	destination_ptr->next = source_ptr;
	int chained_member = (destination_ptr->nested.small =
		destination_ptr->next->nested.small = small_init).b;
	destination_ptr->nested.inner = destination_ptr->next->nested.inner;
	destination_ptr->nested = destination_ptr->next->nested;
	failures += (chained_member == 5 && destination_ptr->nested.small.a == 3 &&
		destination_ptr->nested.small.b == 5 && destination_ptr->nested.inner.left == 37 &&
		destination_ptr->nested.inner.right == 41 &&
		destination_ptr->next->nested.small.a == 3 &&
		destination_ptr->next->nested.small.b == 5) ? 0 : 64;

	union Value local_a = { .i = 19 };
	union Value local_b = { .i = 23 };
	union Value local_init = local_a;
	local_init = local_b;
	union Value union_ternary = take_source ? local_a : local_b;
	int union_ternary_member = (take_source ? local_a : local_b).i;
	failures += (global_value.i == 73 && local_init.i == 23 &&
		union_ternary.i == 19 && union_ternary_member == 19) ? 0 : 128;

	struct Padded padded_source = { 'p', 123456789L, 'q' };
	struct Padded padded_init = padded_source;
	struct Padded padded_copy = { 0 };
	padded_copy = padded_init;
	padded_copy.value += 1;
	failures += (padded_copy.tag == 'p' && padded_copy.value == 123456790L &&
		padded_copy.tail == 'q') ? 0 : 256;

	return failures;
}
