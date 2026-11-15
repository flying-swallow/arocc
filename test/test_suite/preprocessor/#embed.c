// #opt: --embed-dir=embed -std=c23
unsigned char hello[] = {
#embed "embed data"
	, 0 // #embed does not provide a trailing NULL byte
};
_Static_assert(sizeof(hello) == sizeof("Hello, World!"), "");

int empty[] = {
#embed "empty"
};
_Static_assert(sizeof(empty) == 0, "");

const int Foo = 1 +
#embed "embed byte"
;

_Static_assert(Foo == 1 + 'A', "");

unsigned char third[] = {
#embed "embed data" __limit__(3) prefix(0, 1,) suffix(,3, 4) limit(4) // #warning@62: duplicate embed parameter 'limit' [-Wduplicate-embed-param]
};

_Static_assert(sizeof(third) == 2 + 4 + 2, "");

const int bar =
#embed "embed data" limit(a) limit(1) // #warning@30: duplicate embed parameter 'limit' [-Wduplicate-embed-param]
;
_Static_assert(bar == 'H', "");

# if __has_embed("embed data" foo(1)) != __STDC_EMBED_NOT_FOUND__
#error unknown param was accepted
#endif

# if __has_embed("doesn't exist") != __STDC_EMBED_NOT_FOUND__
#error non-existent embed found
#endif

# if __has_embed("embed data" limit(1)) != __STDC_EMBED_FOUND__
#error embed should be found
#endif

# if __has_embed("empty") != __STDC_EMBED_EMPTY__
#error empty wasn't detected
#endif

const int expanded_byte =
#define B limit
#define A <embed
#embed A data> B(1)
;
_Static_assert(expanded_byte == 'H', "");

#embed "empty" vendor::unsupported // #error@24: unknown embed parameter 'vendor::unsupported'
#embed "empty" vendor::unsupported(2) // #error@24: unknown embed parameter 'vendor::unsupported'
#embed "empty" vendor::
#embed "empty" limit // #error@24: expected identifier // #error@16: expected '('
#embed "empty" limit(-1) // #error@16: the limit parameter expects a non-negative integer as a parameter
#embed "empty" limit(1) 1 limit(3) // #error@25: expected identifier

