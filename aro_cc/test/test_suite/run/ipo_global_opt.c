// #kind: run
// #exit: 0

static int never_written = 37;
static int mutable_value = 5;
static volatile int volatile_value = 9;
static const int constant_array[3] = { 3, 5, 8 };
static int bss_zero;
static int write_only;
static int escaped_value = 23;
static int cross_function_value = 2;
static const int indexed_values[3] = { 11, 13, 17 };
static int relocation_target = 29;
static int *relocation_pointer = &relocation_target;
int externally_visible_value = 31;
struct VolatileField { volatile int value; };
static struct VolatileField volatile_field = { 41 };
static const char *same_literal_a = "same literal";
static const char *same_literal_b = "same literal";
static const char *distinct_literal = "distinct literal";

static int *escaped_address(void)
{
	return &escaped_value;
}

static void update_escaped_value(void)
{
	*escaped_address() = 27;
}

static void write_cross_function(int value)
{
	cross_function_value = value;
}

static int read_cross_function(void)
{
	return cross_function_value;
}

static int read_unknown_offset(int offset)
{
	return indexed_values[offset];
}

static int read_relocation_target(void)
{
	return relocation_target;
}

static int read_volatile_field(void)
{
	return volatile_field.value;
}

int read_mutable(void)
{
	return mutable_value;
}

void write_mutable(int value)
{
	mutable_value = value;
}

int read_volatile(void)
{
	return volatile_value;
}

int main(void)
{
	if (never_written != 37) return 1;
	if (read_mutable() != 5) return 2;
	write_mutable(11);
	if (read_mutable() != 11) return 3;
	if (read_volatile() != 9) return 4;
	if (constant_array[1] != 5) return 5;
	if (bss_zero != 0) return 6;
	write_only = 99;
	update_escaped_value();
	if (*escaped_address() != 27) return 7;
	write_cross_function(7);
	if (read_cross_function() != 7) return 8;
	if (read_unknown_offset(2) != 17) return 9;
	if (read_relocation_target() != 29 || *relocation_pointer != 29) return 10;
	if (externally_visible_value != 31) return 11;
	if (read_volatile_field() != 41) return 12;
	if (same_literal_a[0] != same_literal_b[0] || same_literal_a[5] != same_literal_b[5]) return 13;
	if (distinct_literal[0] != 'd') return 14;
	return 0;
}
