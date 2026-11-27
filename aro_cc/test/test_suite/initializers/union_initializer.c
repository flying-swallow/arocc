// #kind: expand_error
/** manifest:
expand_error
*/
// Union selection by field designator, preserved by preprocessing.
union Number { int integer; double real; };
union Number value = { .real = 2.5 };
