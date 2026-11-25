// #skip: diagnostics differ (aro_c3 gap)
// #opt: -Wno-deprecated-non-prototype -std=c17
int foo(int bar) {
    (void)sizeof(struct Foo { int a; });
    (void)__alignof(struct Foo);
    return bar;
}

int fooo(bar, baz)
    float bar;
    int *baz;
    double quux; // #error@12: parameter named 'quux' is missing
{
    return *baz * bar;
}

int foooo(n, bar)
    int n;
    int bar[n];
{}

int bar(int) = foo; // #error@14: illegal initializer (only variables can be initialized)

int baz(int a[*]) { // #error@13: variable length array must be bound in function definition
    return a[0];
}

static int GLOBAL = 1;
int nested_scopes(int a, int b) {
    if (a == 1) {
        int target;
        target = 1;
        return b == target;
    } else {
        int target = 2;
        if (b == target) {
            return GLOBAL == 1;
        }
        return target == 2;
    }
}

struct S;
void forward_decl_struct(struct S s) {} // #error@35: parameter has incomplete type 'struct S'
void forward_decl_struct_old(s)
struct S s; // #error@10: parameter has incomplete type 'struct S'
{}

typedef union Union U;
void forward_decl_union_td(U u) {} // #error@30: parameter has incomplete type 'U' (aka 'union Union')
void forward_decl_union_td_old(u)
U u; // #error@3: parameter has incomplete type 'U' (aka 'union Union')
{}

void inline_decl_enum(enum E e) {} // #error@30: parameter has incomplete type 'enum E'
void inline_decl_enum_old(e)
enum EE e; // #error@9: parameter has incomplete type 'enum EE'
{}

void unspecified_variable_len(int, int [][*]);
typedef void (*func_pointer)(int, int[][*]);

void unspecified_variable_len(int n, int x[][n]) { }

static func_pointer p = unspecified_variable_len;

void static_array_parameter(x)
	int x[static 5];
{}

int(wrapped)(void) {
   return 0;
}

int ARRAY[2];
int (*return_array_ptr(void))[2] {
    return &ARRAY;
}

void no_params(void); // #note@6: previous definition is here
void no_params(int x){} // #error@6: redefinition of 'no_params' with a different type

void invalid_func(__auto_type); // #error@19: '__auto_type' not allowed in function prototype
int invalid_int = invalid_func;

void desugar_func_ty(void) {
    typedef int foo;
    foo bar(foo);
    int *ptr = bar; // #warning@16: incompatible pointer types initializing 'int *' from incompatible type 'foo (foo)' (aka 'int (int)') [-Wincompatible-pointer-types]
}

void returning_void(void) {
    return desugar_func_ty();
}

