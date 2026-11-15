// #skip: diagnostics differ (aro_c3 gap)
// #opt: -std=c11
#pragma GCC diagnostic warning "-Wc99-compat"

#define Ǻ 42
int fǿǿ(void) {
    int Ǿ = Ǻ;
    return Ǿ;
}

int bȁr(void) {
    int ™ = 0; // #warning@9: using this character in an identifier is incompatible with C99 [-Wc99-compat]
    return 0;
}

int bȁz(void) {
    int a١ = 0;
    int ١a = 0;
    return 0;
}

int invis­ible = 0; // #warning@10: using this character in an identifier is incompatible with C99 [-Wc99-compat] // #warning@10: identifier contains Unicode character <U+00AD> that is invisible in some environments [-Wunicode-homoglyph]
int homoglyph） = 1; // #warning@14: using this character in an identifier is incompatible with C99 [-Wc99-compat] // #warning@14: treating Unicode character <U+FF09> as identifier character rather than as ')' symbol [-Wunicode-homoglyph]

struct gǿǿd {
    int ǿk;
};

struct £ { // #error@8: unexpected character <U+00A3> // #warning@1: declaration does not declare anything [-Wmissing-declaration]
    int pounds;
};
struct cents {
    int ¢; // #error@9: unexpected character <U+00A2> // #warning@10: declaration does not declare anything [-Wmissing-declaration]
};

int あああ =  "あああ" * 1; // #error@18: invalid operands to binary expression ('char [10]' and 'int')

