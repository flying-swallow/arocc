// #kind: expand_error
#if defined __has_attribute
#  if __has_attribute(aligned)
      #error attribute exists // #error@8: attribute exists
#  endif
#  if __has_attribute(does_not_exist)
      #error attribute exists
#  endif
#endif

#define FOO aligned
#if !__has_attribute(FOO)
#  error should have attribute aligned
#endif

