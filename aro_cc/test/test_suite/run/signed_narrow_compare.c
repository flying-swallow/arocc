// #kind: run
// #exit: 0
// Compares on odd-width _BitInt values must use the exact IR width: x86
// operates at the rounded register width, so the bits above it are dirty after
// wrapping arithmetic and must be sign- (signed) or zero- (unsigned, ==)
// extended before cmp. `volatile` keeps one side lowered instead of folded.

#define CHECK_SIGNED(T, MIN, MAX, BIT)                                        \
    do {                                                                      \
        volatile T vmin = MIN, vmax = MAX, vneg = -1, vzero = 0;              \
        T min = vmin, max = vmax, neg = vneg, zero = vzero;                   \
        if (!(min < max) || !(neg < zero) || !(min < neg) || !(zero < max))   \
            bad |= BIT;                                                       \
        if (!(max > min) || !(zero > neg) || (min > zero) || (neg > max))     \
            bad |= BIT;                                                       \
        if (!(min <= min) || !(neg <= zero) || (max <= neg))                  \
            bad |= BIT;                                                       \
        if (!(max >= max) || !(zero >= neg) || (min >= zero))                 \
            bad |= BIT;                                                       \
    } while (0)

int main(void)
{
    int bad = 0;
    CHECK_SIGNED(signed _BitInt(2), -2, 1, 1);
    CHECK_SIGNED(signed _BitInt(3), -4, 3, 2);
    CHECK_SIGNED(signed _BitInt(17), -65536, 65535, 4);

    // Wrapping unsigned arithmetic leaves a carry above the exact width.
    volatile unsigned _BitInt(3) u3 = 7;
    unsigned _BitInt(3) w3 = u3 + 1;
    if (w3 != 0 || !(w3 < 1)) bad |= 8;
    volatile unsigned _BitInt(17) u17 = 131071;
    unsigned _BitInt(17) w17 = u17 + 1;
    if (w17 != 0 || w17 > 0) bad |= 16;
    volatile unsigned _BitInt(1) u1 = 1;
    unsigned _BitInt(1) w1 = u1 + 1;
    if (w1 != 0) bad |= 32;

    // A signed value produced by wrapping unsigned arithmetic: 3 + 1 is -4 in i3.
    volatile unsigned _BitInt(3) three = 3;
    signed _BitInt(3) wrapped = (signed _BitInt(3))(unsigned _BitInt(3))(three + 1);
    if (!(wrapped < 0)) bad |= 64;
    long widened = wrapped;
    if (widened != -4) bad |= 128;
    return bad;
}
