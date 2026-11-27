#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef struct { uint32_t id; int active; } tracy_ctx;
typedef struct {
    const char *name, *function, *file;
    uint32_t line, color;
} tracy_source_location;
enum {
    ZONE_BEGIN = 1, ZONE_BEGIN_CALLSTACK, ZONE_TEXT, ZONE_NAME, ZONE_COLOR,
    ZONE_VALUE, ZONE_END, ALLOC, ALLOC_CALLSTACK, FREE, FREE_CALLSTACK,
    ALLOC_NAMED, ALLOC_CALLSTACK_NAMED, FREE_NAMED, FREE_CALLSTACK_NAMED,
    MESSAGE, MESSAGE_L, MESSAGE_C, MESSAGE_LC, FRAME, FRAME_START, FRAME_END
};
static int events[256];
static uint32_t event_count;
static int source_ok, zone_args_ok, message_args_ok, memory_args_ok;
static const char *last_frame_name;
static unsigned frame_mark_count;
static int expected_depth;
static unsigned allocation_count, free_count;
static void *allocation_pointers[4];
static void record(int event) {
    if (event_count < sizeof(events) / sizeof(events[0])) events[event_count++] = event;
}
void tracy_test_reset(void) {
    event_count = 0;
    frame_mark_count = 0;
    allocation_count = free_count = 0;
    source_ok = zone_args_ok = message_args_ok = memory_args_ok = 1;
    last_frame_name = NULL;
}
uint32_t tracy_test_event_count(void) { return event_count; }
int tracy_test_event_at(uint32_t index) { return index < event_count ? events[index] : 0; }
int tracy_test_zone_source_ok(void) { return source_ok; }
int tracy_test_zone_args_ok(void) { return zone_args_ok; }
int tracy_test_message_args_ok(void) { return message_args_ok; }
int tracy_test_memory_args_ok(void) { return memory_args_ok; }
void tracy_test_expect_callstack(int depth) { expected_depth = depth; }
int tracy_test_abi_sizes_ok(void) {
    return sizeof(tracy_ctx) == 8 && offsetof(tracy_ctx, id) == 0 &&
           offsetof(tracy_ctx, active) == 4 && sizeof(tracy_source_location) == 32 &&
           offsetof(tracy_source_location, name) == 0 &&
           offsetof(tracy_source_location, function) == 8 &&
           offsetof(tracy_source_location, file) == 16 &&
           offsetof(tracy_source_location, line) == 24 &&
           offsetof(tracy_source_location, color) == 28;
}
static void check_source(const tracy_source_location *src, int named, uint32_t line) {
    source_ok &= src && src->function && strcmp(src->function, "worker") == 0;
    source_ok &= src && src->file && strcmp(src->file, "worker.c3") == 0;
    source_ok &= src && src->line == line && src->color == 0;
    source_ok &= src && ((named && src->name && strcmp(src->name, "named") == 0) ||
                         (!named && src->name == NULL));
}
tracy_ctx ___tracy_emit_zone_begin(const tracy_source_location *src, int active) {
    check_source(src, src && src->line == 74, src && src->line == 74 ? 74 : 73); zone_args_ok &= active == 1;
    record(ZONE_BEGIN); return (tracy_ctx){41, active};
}
tracy_ctx ___tracy_emit_zone_begin_callstack(const tracy_source_location *src, int depth, int active) {
    check_source(src, src && src->line == 74, src && src->line == 74 ? 74 : 73);
    zone_args_ok &= depth == expected_depth && active == 1;
    record(ZONE_BEGIN_CALLSTACK); return (tracy_ctx){42, active};
}
void ___tracy_emit_zone_text(tracy_ctx ctx, const char *text, size_t size) {
    zone_args_ok &= (ctx.id == 41 || ctx.id == 42) && ctx.active == 1 && text && size == 7 && memcmp(text, "payload", 7) == 0; record(ZONE_TEXT);
}
void ___tracy_emit_zone_name(tracy_ctx ctx, const char *text, size_t size) {
    zone_args_ok &= (ctx.id == 41 || ctx.id == 42) && ctx.active == 1 && text && size == 10 && memcmp(text, "named zone", 10) == 0; record(ZONE_NAME);
}
void ___tracy_emit_zone_color(tracy_ctx ctx, uint32_t color) { zone_args_ok &= (ctx.id == 41 || ctx.id == 42) && ctx.active == 1 && color == 0x123456; record(ZONE_COLOR); }
void ___tracy_emit_zone_value(tracy_ctx ctx, uint64_t value) { zone_args_ok &= (ctx.id == 41 || ctx.id == 42) && ctx.active == 1 && value == UINT64_C(0x1122334455667788); record(ZONE_VALUE); }
void ___tracy_emit_zone_end(tracy_ctx ctx) { zone_args_ok &= (ctx.id == 41 || ctx.id == 42) && ctx.active == 1; record(ZONE_END); }
static void check_alloc(void *p, size_t size, int secure, int named) {
    static const size_t expected_sizes[] = {24, 48, 16, 12};
    memory_args_ok &= p != NULL && secure == 0 && allocation_count < 4;
    if (allocation_count < 4) {
        memory_args_ok &= size == expected_sizes[allocation_count];
        allocation_pointers[allocation_count] = p;
    }
    if (named) memory_args_ok &= allocation_count == 2;
    else memory_args_ok &= allocation_count != 2;
    allocation_count++;
}
static void check_free(void *p, int secure, int named) {
    memory_args_ok &= p != NULL && secure == 0 && free_count < allocation_count &&
                      free_count < 4 && allocation_pointers[free_count] == p;
    if (named) memory_args_ok &= free_count == 2;
    else memory_args_ok &= free_count != 2;
    free_count++;
}
void ___tracy_emit_memory_alloc(void *p, size_t s, int sec) { check_alloc(p,s,sec,0); record(ALLOC); }
void ___tracy_emit_memory_alloc_callstack(void *p, size_t s, int d, int sec) { check_alloc(p,s,sec,0); memory_args_ok &= d == expected_depth; record(ALLOC_CALLSTACK); }
void ___tracy_emit_memory_free(void *p, int sec) { check_free(p,sec,0); record(FREE); }
void ___tracy_emit_memory_free_callstack(void *p, int d, int sec) { check_free(p,sec,0); memory_args_ok &= d == expected_depth; record(FREE_CALLSTACK); }
void ___tracy_emit_memory_alloc_named(void *p, size_t s, int sec, const char *name) { check_alloc(p,s,sec,1); memory_args_ok &= name && strcmp(name,"arena")==0; record(ALLOC_NAMED); }
void ___tracy_emit_memory_alloc_callstack_named(void *p, size_t s, int d, int sec, const char *name) { check_alloc(p,s,sec,1); memory_args_ok &= d == expected_depth && name && strcmp(name,"arena")==0; record(ALLOC_CALLSTACK_NAMED); }
void ___tracy_emit_memory_free_named(void *p, int sec, const char *name) { check_free(p,sec,1); memory_args_ok &= name && strcmp(name,"arena")==0; record(FREE_NAMED); }
void ___tracy_emit_memory_free_callstack_named(void *p, int d, int sec, const char *name) { check_free(p,sec,1); memory_args_ok &= d == expected_depth && name && strcmp(name,"arena")==0; record(FREE_CALLSTACK_NAMED); }
void ___tracy_emit_message(char *text, size_t size, int callstack) { message_args_ok &= text && size == 14 && memcmp(text,"copied message",14)==0 && callstack == expected_depth; record(MESSAGE); }
void ___tracy_emit_messageL(const char *text, int callstack) { message_args_ok &= text && callstack == expected_depth; record(MESSAGE_L); }
void ___tracy_emit_messageC(char *text, size_t size, uint32_t color, int callstack) { message_args_ok &= text && size == 22 && memcmp(text,"copied colored message",22)==0 && color == 0x654321 && callstack == expected_depth; record(MESSAGE_C); }
void ___tracy_emit_messageLC(const char *text, uint32_t color, int callstack) {
    message_args_ok &= text && callstack == expected_depth;
    if (strcmp(text,"colored message") == 0) { message_args_ok &= color == 0xabcdef; }
    if (strcmp(text,"allocation failed") == 0) message_args_ok &= color == 0xff0000;
    record(MESSAGE_LC);
}
void ___tracy_emit_frame_mark(const char *name) {
    if (frame_mark_count == 0) message_args_ok &= name == NULL;
    else if (frame_mark_count == 1) message_args_ok &= name && strcmp(name, "frame") == 0;
    frame_mark_count++;
    record(FRAME);
}
void ___tracy_emit_frame_mark_start(const char *name) { message_args_ok &= name && strcmp(name, "scoped frame") == 0; last_frame_name = name; record(FRAME_START); }
void ___tracy_emit_frame_mark_end(const char *name) { message_args_ok &= name && last_frame_name && strcmp(name, last_frame_name) == 0; record(FRAME_END); }
