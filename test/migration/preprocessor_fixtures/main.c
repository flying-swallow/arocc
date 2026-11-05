#define HEADER "include/once.h"
#include HEADER
#include "include/once.h"
#include "include/recursive.h"

#if __has_include("include/query_only.h")
int query_result = 1;
#else
int query_result = 0;
#endif
int missing_query_result = __has_include("absent.h");
int embed_query_result = __has_embed("payload.bin") == 1;

unsigned char payload[] = {
#embed "payload.bin" limit(2) prefix(9,) suffix(,8)
};

int empty_payload[] = {
#embed "empty.bin" if_empty(77)
};

#include <next.h>
#include <Sample/Value.h>
int next_value = NEXT_VALUE;
const char* timestamp_value = __TIMESTAMP__;
