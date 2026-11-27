// #todo: TODO: implement 'alloc_align' attribute
__attribute__((alloc_align(0))) int* foo1(int x, double y); // #warning@16: TODO: implement 'alloc_align' attribute
__attribute__((alloc_align(1))) int* foo2(int x, double y); // #warning@16: TODO: implement 'alloc_align' attribute
__attribute__((alloc_align(2))) int* foo3(int x, double y); // #warning@16: TODO: implement 'alloc_align' attribute
__attribute__((alloc_align(3))) int* foo4(int x, double y); // #warning@16: TODO: implement 'alloc_align' attribute
__attribute__((alloc_align(1))) int foo5(int x, double y); // #warning@16: TODO: implement 'alloc_align' attribute

