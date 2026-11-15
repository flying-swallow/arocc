// #skip: diagnostics differ (aro_c3 gap)
// #opt: -Wno-deprecated-non-prototype
// Test for situations where the parser behavior depends on the type, to ensure
// that typeof() is handled correctly.

void typeof_array_initializer_list(void) {
    typeof(char[3]) arr = {1,2,3};
    typeof(arr) arr2 = {1,2,3};

    static char static_arr[3] = {1,2,3};
    typeof(static_arr) static_arr2 = {1,2,3};
}

void typeof_array_string_init(void) {
    typeof(char[6]) arr = "Hello";
    typeof(arr) arr2 = "Hello";

    static char static_arr[6] = "Hello";
    typeof(static_arr) static_arr2 = "Hello";
}

void array_index_warning(void) {
    typeof(int[5]) arr;
    typeof(arr) arr2;
    static int static_arr[5];
    typeof(static_arr) static_arr2;

    (void)arr[5]; // #warning@14: array index 5 is past the end of the array [-Warray-bounds]
    (void)arr2[5]; // #warning@15: array index 5 is past the end of the array [-Warray-bounds]
    (void)static_arr2[5]; // #warning@22: array index 5 is past the end of the array [-Warray-bounds]
}

void extra_record_inits(void) {
    struct S {int x; };
    typeof(struct S) s = { 1, 2 }; // #warning@31: excess elements in struct initializer [-Wexcess-initializers]
    typeof(s) s2 = { 1, 2 }; // #warning@25: excess elements in struct initializer [-Wexcess-initializers]

    union U { int x; };
    typeof(union U) u = { 1, 2 }; // #warning@30: excess elements in union initializer [-Wexcess-initializers]
    typeof(u) u2 = { 1 , 2 }; // #warning@26: excess elements in union initializer [-Wexcess-initializers]
}

void incomplete_array(void) {
    typeof(int[]) arr = {1, 2, 3};
    typeof(arr) arr2 = {1, 2, 3};
}

void voidparams(typeof(const void), ...); // #error@35: 'void' must be the only parameter if specified // #error@35: 'void' parameter cannot be qualified

void string_initializer(void) {
     typeof(char[2]) arr = "hello"; // #warning@28: initializer-string for char array is too long [-Wexcess-initializers]
     typeof(arr) arr2 = "hello"; // #warning@25: initializer-string for char array is too long [-Wexcess-initializers]
}

void old_style(x, y)
    typeof(void) x; // #error@18: parameter cannot have void type
    typeof(x) y; // #error@15: parameter cannot have void type
{
}

void do_not_coerce_extra_initializers(void) {
    typeof(int[2]) arr = {1,2,"hello"}; // #warning@31: excess elements in array initializer [-Wexcess-initializers]
    typeof(arr) arr2 = {1,2,"hello"}; // #warning@29: excess elements in array initializer [-Wexcess-initializers]
}

void bool_init(void) {
    struct S {int x;};
    struct S s = {1};
    typeof(_Bool) b = s; // #error@23: initializing 'typeof(_Bool)' (aka '_Bool') from incompatible type 'struct S'
    typeof(b) b2 = s; // #error@20: initializing 'typeof(typeof(_Bool))' (aka '_Bool') from incompatible type 'struct S'
}

