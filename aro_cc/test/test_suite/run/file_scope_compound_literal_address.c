// #kind: run
// #exit: 0
// File-scope compound literals have static storage: their addresses (and array
// decay) are address constants (c-testsuite 00149/00150, chibicc parse.c).
typedef struct Tree { int v; struct Tree *l, *r; } Tree;
Tree *root = &(Tree){ 1, &(Tree){ 2, &(Tree){ 3, 0, 0 }, 0 }, &(Tree){ 4, 0, 0 } };
int *arr = (int[]){ 5, 6, 7 };
int *mid = &(int[]){ 8, 9, 10 }[1];
static int sum(Tree *t) { return t ? t->v + sum(t->l) + sum(t->r) : 0; }
int main(void) { root->v += 100; return !(sum(root) == 110 && arr[2] == 7 && *mid == 9); }
