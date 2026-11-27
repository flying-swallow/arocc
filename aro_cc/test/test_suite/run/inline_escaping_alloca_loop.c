// #kind: run
// #exit: 0

static int *published_address;

/* The helper's local address escapes into global storage, which must keep the
   inlined alloca from promotion even though the dereferences happen before return. */
static inline int publish_address(int value)
{
	int local = value;
	published_address = &local;
	*published_address += 1;
	return *published_address;
}

int main(void)
{
	int sum = 0;
	for (int i = 0; i < 10; i++) {
		sum += publish_address(i);
	}
	return sum == 55 ? 0 : 1;
}
