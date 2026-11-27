// #kind: run
// #exit: 0
// __atomic_load_n/__atomic_store_n/fences (IR ATOMIC_LOAD/ATOMIC_STORE/FENCE)
// and __builtin_clz/ctz (IR CLZ/CTZ) across widths and memory orders.
typedef unsigned long long u64;

static long long counter;
static int flag;
static char small;
static int *slot;

static int clz32(unsigned x) { return __builtin_clz(x); }
static int clz64(u64 x) { return __builtin_clzll(x); }
static int ctz32(unsigned x) { return __builtin_ctz(x); }
static int ctz64(u64 x) { return __builtin_ctzll(x); }
static int clz16(unsigned short x) { return __builtin_clzs(x); }

int main(void) {
    int target = 5;
    __atomic_store_n(&counter, 41, __ATOMIC_RELAXED);
    __atomic_store_n(&counter, __atomic_load_n(&counter, __ATOMIC_ACQUIRE) + 1, __ATOMIC_SEQ_CST);
    if (__atomic_load_n(&counter, __ATOMIC_SEQ_CST) != 42) return 1;
    __atomic_store_n(&flag, -7, __ATOMIC_RELEASE);
    if (__atomic_load_n(&flag, __ATOMIC_RELAXED) != -7) return 2;
    __atomic_store_n(&small, 200, __ATOMIC_SEQ_CST);
    if ((unsigned char)__atomic_load_n(&small, __ATOMIC_SEQ_CST) != 200) return 3;
    __atomic_store_n(&slot, &target, __ATOMIC_RELEASE);
    if (*__atomic_load_n(&slot, __ATOMIC_ACQUIRE) != 5) return 4;
    __atomic_thread_fence(__ATOMIC_SEQ_CST);
    __atomic_thread_fence(__ATOMIC_ACQ_REL);
    __atomic_signal_fence(__ATOMIC_SEQ_CST);
    __sync_synchronize();

    if (clz32(1) != 31 || clz32(0x80000000u) != 0 || clz32(0x00ff0000u) != 8) return 10;
    if (clz64(1) != 63 || clz64(1ULL << 63) != 0 || clz64(0x100000000ULL) != 31) return 11;
    if (ctz32(1) != 0 || ctz32(0x80000000u) != 31 || ctz32(0x00ff0000u) != 16) return 12;
    if (ctz64(1ULL << 63) != 63 || ctz64(0x100000000ULL) != 32 || ctz64(6) != 1) return 13;
    if (clz16(1) != 15 || clz16(0x8000) != 0 || clz16(0x0100) != 7) return 14;
    return 0;
}
