// #kind: run
// #exit: 0

#include <stdint.h>

static int *saved_pointer;

static void capture_leaf(int *p)
{
	saved_pointer = p + 1;
}

static void capture_through_call(int *p)
{
	capture_leaf(p);
}

static void (* volatile indirect_capture)(int *) = capture_leaf;

static void capture_through_indirect_call(int *p)
{
	indirect_capture(p);
}

static void write_integer(long x)
{
	*(int *)x = 43;
}

static int *mask(int *p)
{
	return (int *)((uintptr_t)p & ~7UL);
}

static int *off(int *p)
{
	return (int *)((uintptr_t)p + 4);
}

static int *via(int *p)
{
	int *slot[1];
	slot[0] = p;
	return slot[0];
}

static void wv(int *p)
{
	int *slot[1];
	slot[0] = p;
	int *reloaded = slot[0];
	*reloaded = 47;
}

static void phi_write(int *a, int *b, int c)
{
	int *selected = c ? a : b;
	*selected = c ? 48 : 49;
}

int main(void)
{
	int values[3] = { 10, 20, 30 };
	capture_through_call(values);
	values[1] = 41;
	if (saved_pointer != &values[1] || *saved_pointer != 41) return 1;

	values[2] = 30;
	capture_through_indirect_call(&values[1]);
	values[2] = 42;
	if (saved_pointer != &values[2] || *saved_pointer != 42) return 2;

	/* Pass pointer origins through helper arguments before writing. */
	_Alignas(8) int aligned_values[3] = { 10, 20, 30 };
	write_integer((long)(uintptr_t)&aligned_values[0]);
	if (aligned_values[0] != 43) return 3;

	/* Masking an aligned address preserves its exact pointer origin. */
	int *masked_pointer = mask(&aligned_values[0]);
	*masked_pointer = 44;
	if (masked_pointer != &aligned_values[0] || aligned_values[0] != 44) return 4;

	/* Offset the pointer in the helper and verify the destination address. */
	int *offset_pointer = off(&aligned_values[0]);
	*offset_pointer = 45;
	if (offset_pointer != &aligned_values[1] || aligned_values[1] != 45) return 5;

	/* Store and reload the pointer through the helper's local array slot. */
	int *via_pointer = via(&aligned_values[2]);
	*via_pointer = 46;
	if (via_pointer != &aligned_values[2] || aligned_values[2] != 46) return 6;

	/* Write through a pointer reloaded from a local array slot. */
	wv(&aligned_values[2]);
	if (aligned_values[2] != 47) return 7;

	/* Exercise both arms of a conditional pointer selection in the helper. */
	phi_write(&aligned_values[0], &aligned_values[1], 1);
	if (aligned_values[0] != 48 || aligned_values[1] != 45) return 8;
	phi_write(&aligned_values[0], &aligned_values[1], 0);
	if (aligned_values[0] != 48 || aligned_values[1] != 49) return 9;
	return 0;
}
