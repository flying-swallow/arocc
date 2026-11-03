---
title: 'C3 migration 08 [Types & ABI]: Port type representation and qualified type operations'
state: waiting
depends_on:
- c3-migration-07-replace-zig-target-metadata-with-explicit-c3-tar
planned: true
parent_session: 01a19f7c-d060-7e01-b4aa-ce62ed71b1e2
sessions:
- 01a1a1dc-3140-7cf3-9e54-62aece9a8227
---

Add src/c3/type_store.c3 and test/c3/type_store_tests.c3; extend compilation storage and register //test/c3:type_store_tests. Follow src/aro/TypeStore.zig Repr/Index/QualType/Type, put/putExtra/set, base/get/childType, equality, promotions, rank, decay, sizeofOrNull/alignof and type printing. Preserve invalid/auto/incomplete distinctions, qualifiers, attributed wrappers, arrays/VLAs/functions/pointers, atomic/vector/complex/_BitInt types and mutable completion of forward record/enum declarations. Use stable indexed handles and explicit tagged records instead of exposing C3 pointers as type identity. Port initNamedTypes/generateVaListType against explicit C3 target data; store record layout results but defer layout computation and parser-coupled Builder specifier diagnostics to their own steps. Add necessary attribute metadata slots without implementing parser syntax. Acceptance: bazel test //test/c3:type_store_tests covering canonical builtins, qualified equality, recursive declarations, array/function decay, integer promotions, ABI-specific named/va_list types, incomplete size behavior and type-print goldens; force container growth to verify handle stability. Do not use host sizeof for C target layout

For every new //test/c3:* target in this ticket, list its .c3 test source files explicitly in project.json. c3c project source entries do not expand `dir/*.c3`; use explicit paths (the source tree may continue to use `src/c3/**`).
