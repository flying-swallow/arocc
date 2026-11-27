// #opt: --emulate=clang
enum E {
   is_deprecated __attribute__((deprecated)), // #note@33: 'is_deprecated' has been explicitly marked deprecated here
   is_deprecated_with_msg __attribute__((deprecated("I am deprecated"))), // #note@42: 'is_deprecated_with_msg' has been explicitly marked deprecated here
   is_unavailable __attribute__((unavailable)), // #note@34: 'is_unavailable' has been explicitly marked unavailable here
   is_unavailable_with_msg  __attribute__((unavailable("I am not available"))), // #note@44: 'is_unavailable_with_msg' has been explicitly marked unavailable here
   newval,
};

void foo(void) {
  int a = newval;
  a = is_deprecated; // #warning@7: 'is_deprecated' is deprecated [-Wdeprecated-declarations]
  a = is_deprecated_with_msg; // #warning@7: 'is_deprecated_with_msg' is deprecated: I am deprecated [-Wdeprecated-declarations]
  a = is_unavailable; // #error@7: 'is_unavailable' is unavailable
  a = is_unavailable_with_msg; // #error@7: 'is_unavailable_with_msg' is unavailable: I am not available
}

enum __attribute__((aligned(16))) Attributed {
  Val,
};
_Static_assert(_Alignof(enum Attributed) == 16, "enum align");

enum Trailing {
  Foo
} __attribute__((aligned(32)));
_Static_assert(_Alignof(enum Trailing) == 32, "enum align");

enum __attribute__((vector_size(32))) VectorSize1;

enum __attribute__((vector_size(32))) VectorSize2 {
    A
};

