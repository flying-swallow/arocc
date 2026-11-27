/** manifest:
syntax
*/
_Static_assert(__builtin_choose_expr(1, 17, 23) == 17, "selected branch is constant");
