// #kind: run
// #exit: 0
// GNU statement expressions, including the empty `({})` (gcc compat
// struct-layout-1 crashed lowering it) and block-scoped declarations.
int main(void){ ({}); int x = ({ int y = 3; y + 1; }); ({ int y = 9; (void)y; }); return x - 4; }
