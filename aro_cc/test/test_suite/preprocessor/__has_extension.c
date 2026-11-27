// #kind: expand_error
#if defined __has_extension
#  if __has_extension(c_alignas)
      #error extension exists // #error@8: extension exists
#  endif
#  if __has_extension(does_not_exist)
      #error extension exists
#  endif
#endif

