/** manifest:
syntax

unterminated comment in preprocessor expression.c:11:5: error: unterminated comment
unterminated comment in preprocessor expression.c:11:1: error: expected value in expression
unterminated comment in preprocessor expression.c:11:1: error: unterminated conditional directive
*/

#if /*

 // #error@5: unterminated comment // #error@1: expected value in expression // #error@1: unterminated conditional directive