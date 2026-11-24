// #kind: run
// #exit: 0
// Reduced from sqlite3KeyInfoFromExprList. `k->coll[i - start]` lowers to
// `add (add k, 32), (mul (i - start), 8)`, which x86-64 lowering emits as one
// LEA reading `k` and `i - start` directly. The register allocator must keep
// both of those live up to the LEA, or the base register is reused for the
// index and the store goes through a garbage pointer.

struct item
{
    void *expr;
    long pad;
    unsigned char sort_flags;
};

struct key_info
{
    int n;
    int unused;
    long pad[3];
    void *coll[8];
    unsigned char *sort_flags;
};

__attribute__((noinline)) static void *coll_for(void *parse, void *expr)
{
    return (char *)expr + (parse != 0);
}

__attribute__((noinline)) static int fill(void *parse, struct key_info *k, struct item *items, int start, int n)
{
    int i;
    struct item *item;
    for (i = start, item = items + start; i < n; i++, item++)
    {
        k->coll[i - start] = coll_for(parse, item->expr);
        k->sort_flags[i - start] = item->sort_flags;
    }
    return n - start;
}

int main(void)
{
    char base[16];
    unsigned char flags[8] = { 0 };
    struct item items[6];
    struct key_info k = { 0 };
    k.sort_flags = flags;
    for (int i = 0; i < 6; i++)
    {
        items[i].expr = base + i;
        items[i].sort_flags = (unsigned char)(0x40 + i);
    }
    if (fill(base, &k, items, 2, 6) != 4) return 1;
    for (int i = 0; i < 4; i++)
    {
        if (k.coll[i] != base + i + 2 + 1) return 2;
        if (flags[i] != 0x42 + i) return 3;
    }
    return 0;
}
