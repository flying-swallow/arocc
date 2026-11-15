void foo(void) {
  int a = 0b11 << -32; // #warning@16: shift count is negative [-Wshift-count-negative] // #warning@16: overflow in expression; result is '2147483647' [-Winteger-overflow]
  int b = 0b11 << 32; // #warning@16: shift count >= width of type [-Wshift-count-overflow] // #warning@16: overflow in expression; result is '0' [-Winteger-overflow]
}

