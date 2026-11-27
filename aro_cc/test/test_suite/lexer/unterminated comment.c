// #skip: diagnostics differ (aro_cc gap)
/** manifest:
syntax

unterminated comment.c:8:7: error: unterminated comment
unterminated comment.c:8:6: error: expected ';' before end of file
*/

int x /** // #error@7: unterminated comment // #error@6: expected ';' before end of file