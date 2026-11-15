// #skip: diagnostics differ (aro_c3 gap)
// #opt: -fno-declspec --target=x86_64-linux
__declspec(align(4)) int foo; // #error@1: '__declspec' attributes are not enabled; use '-fdeclspec' or '-fms-extensions' to enable support for __declspec attributes

#if __has_declspec_attribute(noreturn)
#error "__has_declspec_attribute macro should not work without -fdeclspec"
#endif

#if __has_declspec_attribute(x)
#error "__has_declspec_attribute macro should not work without -fdeclspec"
#endif

