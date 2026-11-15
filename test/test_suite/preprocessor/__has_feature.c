// #kind: expand_error
#if defined __has_feature
#  if __has_feature(__enumerator_attributes__)
      #error feature exists // #error@8: feature exists
#  endif
#  if __has_feature(does_not_exist)
      #error feature exists
#  endif
#endif

