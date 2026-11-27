#define HEADER "include/once.h"
#include HEADER
#include "include/once.h"
#include "include/recursive.h"

#if __has_include("include/query_only.h")
int query_result = 1;
#else
int query_result = 0;
#endif
// __has_include/__has_embed are only valid inside preprocessing directives.
#if __has_include("absent.h")
int missing_query_result = 1;
#else
int missing_query_result = 0;
#endif
#if __has_embed("payload.bin") == 1
int embed_query_result = 1;
#else
int embed_query_result = 0;
#endif
#if __has_embed("empty.bin") == 2
int empty_embed_query_result = 2;
#else
int empty_embed_query_result = -1;
#endif
#if __has_embed("absent.bin") == 0
int missing_embed_query_result = 0;
#else
int missing_embed_query_result = -1;
#endif

unsigned char full_payload[] = {
#embed "payload.bin"
};

unsigned char payload[] = {
#embed "payload.bin" limit(2) prefix(9,) suffix(,8)
};

unsigned char zero_limit_payload[] = {
#embed "payload.bin" limit(0) prefix(1,) suffix(,2)
};

int empty_payload[] = {
#embed "empty.bin" if_empty(77)
};

#include <next.h>
#include <Sample/Value.h>
int next_value = NEXT_VALUE;
const char* timestamp_value = __TIMESTAMP__;
