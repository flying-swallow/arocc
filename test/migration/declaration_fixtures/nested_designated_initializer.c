/** manifest:
expand_error
*/
// Nested designators and omitted aggregate members, preserved by preprocessing.
struct Pair { int left; int right; };
struct Outer { struct Pair pair; int tail; };
struct Outer value = { .pair.right = 9 };
