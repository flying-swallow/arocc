// #skip: diagnostics differ (aro_c3 gap)
typedef int (*fnptr)(int, int);


int foo() __attribute__((warn_unused_result)) {
   return 0;
}

fnptr make_fn(int a, int b) {
   return 0;
}

void bar(fnptr ptr) {
   foo(); // #warning@4: ignoring return value of 'foo', declared with 'warn_unused_result' attribute [-Wunused-result]
   (foo)(); // #warning@4: ignoring return value of 'foo', declared with 'warn_unused_result' attribute [-Wunused-result]
   (foo - 16)();
   (foo + 16)();
   (*****foo)(); // #warning@4: ignoring return value of 'foo', declared with 'warn_unused_result' attribute [-Wunused-result]
   make_fn(1, 2)(2, 2);
}

struct S {
  int __attribute__((warn_unused_result))(*close)(void);
};

void baz(struct S *s){
    (bar(0), s->close)(); // #warning@5: ignoring return value of 'close', declared with 'warn_unused_result' attribute [-Wunused-result]
}

