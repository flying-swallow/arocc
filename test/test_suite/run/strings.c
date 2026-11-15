// #kind: run
// #exit: 101
int puts(const char *);
int main(void) { const char *s = "hello"; puts(s); return *(s + 1); }
