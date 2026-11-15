const unsigned char c = u8'A'; // #warning@25: UTF-8 character literal is a C23 extension [-Wc23-extensions]
_Static_assert(c == 'A', "");
#pragma GCC diagnostic ignored "-Wc23-extensions"
_Static_assert(u8'\xff' == 0xFF, "");

const unsigned char c2 = u8'™'; // #error@26: character too large for enclosing character literal type
const unsigned char c3 = u8'£'; // Unicode codepoint 0xA3 // #error@26: character too large for enclosing character literal type
const unsigned char c4 = u8'AA'; // #error@26: Unicode character literals may not contain multiple characters

#if u8'A'
#else
    #error Character constant should be true in preprocessor
#endif

