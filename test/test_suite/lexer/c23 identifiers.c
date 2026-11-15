// #skip: diagnostics differ (aro_c3 gap)
// #opt: -std=c2x
struct £ { // #error@8: unexpected character <U+00A3> // #warning@1: declaration does not declare anything [-Wmissing-declaration]
    int x;
};

void foo(void) {
    int ™ = 0; // #error@9: unexpected character <U+2122> // #error@11: expected identifier or '('
    int ǅ = 0;
    int ʶ = 0;
    int Ⅸ = 9;
    int ڴ = 0;
    int ‿ = 0; // #error@9: unexpected character <U+203F> // #error@11: expected identifier or '('
    int a‿1 = 0;
}

int à = 1; //NFC_Quick_Check=Maybe // #warning@5: 'a\u0300' is not in NFC [-Wnormalized]
int à = 1; //NFC_Quick_Check=No // #warning@5: 'a\u0340' is not in NFC [-Wnormalized]

