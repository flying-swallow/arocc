// #kind: run
// #exit: 0
// Reduced from sqlite pcache1Unpin. After GVN, `&g->lru` (g + 24) is shared by
// a store address and by `&g->lru.next` (g + 24 + 40), which is also stored as
// a value. x86-64 address folding must not drop g + 24 just because both
// memory ops walk through it: g + 64 still reads it as a materialized value.

struct page
{
    long key;
    long pad[4];
    struct page *prev; /* offset 40 */
    struct page *next; /* offset 48 */
};

struct group
{
    long pad[3];
    struct page lru;   /* offset 24 */
    int pinned;
};

__attribute__((noinline)) static void unpin(struct group **pg, struct page *p, int reuse)
{
    struct group *g = *pg;
    if (reuse)
    {
        g->pinned--;
        return;
    }
    struct page **first = &g->lru.next;
    p->prev = &g->lru;
    (p->next = *first)->prev = p;
    *first = p;
    g->pinned++;
}

int main(void)
{
    struct group g = { 0 };
    struct group *pg = &g;
    struct page a = { 1 };
    struct page b = { 2 };
    g.lru.next = &g.lru;
    g.lru.prev = &g.lru;
    unpin(&pg, &a, 0);
    unpin(&pg, &b, 0);
    if (g.lru.next != &b || b.next != &a || a.next != &g.lru) return 1;
    if (a.prev != &b || b.prev != &g.lru) return 2;
    if (g.pinned != 2) return 3;
    return 0;
}
