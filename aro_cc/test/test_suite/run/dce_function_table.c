// #kind: run
// #exit: 0

static int table_callback(void)
{
	return 12;
}

static int struct_callback(int value)
{
	return value + 30;
}

static int (*const callback_table[])(void) = { table_callback };

struct CallbackHolder {
	int (*callback)(int);
};

static const struct CallbackHolder callback_holder = { struct_callback };

int main(void)
{
	if (callback_table[0]() != 12) return 1;
	if (callback_holder.callback(12) != 42) return 2;
	return 0;
}
