// #kind: run
// #exit: 0
// Reduced from sqlite3VdbeSetSql inlined into sqlite3Prepare at -O2: callers
// pass a u8 parameter widened to i32, so the inliner must narrow it back or
// the field store writes four bytes over the following members.
typedef unsigned char u8;
typedef unsigned int u32;
struct V { u8 flags; u8 a; u8 b; u8 c; const char *sql; };

static void set_sql(struct V *p, const char *z, u8 flags) {
    if (p == 0) return;
    p->flags = flags;
    if ((flags & 0x80) == 0) p->a = 0;
    p->sql = z;
}

int main(void) {
    struct V v = { 0, 7, 8, 9, 0 };
    u32 prep = 0x12345680u;
    set_sql(&v, "x", prep);
    return v.flags == 0x80 && v.a == 7 && v.b == 8 && v.c == 9 && v.sql[0] == 'x' ? 0 : 1;
}
