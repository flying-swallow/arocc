extern int puts(const char*);

static const char *f = __func__; // #warning@24: predefined identifier is only valid inside function [-Wpredefined-identifier-outside-function]
static const char *f1 = __FUNCTION__; // #warning@25: predefined identifier is only valid inside function [-Wpredefined-identifier-outside-function]
static const char *f2 = __PRETTY_FUNCTION__; // #warning@25: predefined identifier is only valid inside function [-Wpredefined-identifier-outside-function]

int foo(void) {
    puts(f);
    puts(f1);
    puts(f2);
    puts(__func__);
    puts(__FUNCTION__);
    puts(__PRETTY_FUNCTION__);
    return 0;
}
long *bar(int a) {
    puts(__FUNCTION__);
    puts(__func__);
    puts(__PRETTY_FUNCTION__);
    return 0;
}

