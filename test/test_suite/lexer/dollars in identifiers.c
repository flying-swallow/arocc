// #skip: diagnostics differ (aro_c3 gap)
void foo$() { }

void fib() {
  int $test;
}

void ano$ther() {}

#pragma GCC diagnostic warning "-Wdollar-in-identifier-extension"

void identi$fier() {} // #warning@12: '$' in identifier [-Wdollar-in-identifier-extension]

void inside() {
  int vari$able; // #warning@11: '$' in identifier [-Wdollar-in-identifier-extension]
}

