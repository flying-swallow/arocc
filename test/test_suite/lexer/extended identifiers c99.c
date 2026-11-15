// #skip: diagnostics differ (aro_c3 gap)
// #opt: -std=c99
#define Ǻ 42
int fǿǿ(void) {
    int Ǿ = Ǻ;
    return Ǿ;
}

int bȁr(void) {
    int ™ = 0; // #error@9: unexpected character <U+2122> // #error@11: expected identifier or '('
    return 0;
}

int bȁz(void) {
    int a١ = 0;
    int ١a = 0; // #error@9: character <U+0661> not allowed at the start of an identifier
    return 0;
}

int uǿ = 0;
int uǿ1 = 0;
int u8ǿ = 0;
int u8ǿ1 = 0;
int Uǿ = 0;
int Uǿ1 = 0;
int Lǿ = 0;
int Lǿ1 = 0;

