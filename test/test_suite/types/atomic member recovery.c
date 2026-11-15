struct S { int x; };
int *indirect(_Atomic(struct S) *p) {
    return &p->x; // #error@16: accessing a member of atomic type '_Atomic(struct S)' is undefined behavior
}
int *direct(_Atomic(struct S) a) {
    return &a.x; // #error@15: accessing a member of atomic type '_Atomic(struct S)' is undefined behavior
}

