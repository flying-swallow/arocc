/** manifest:
syntax

unterminated char literal.c:15:11: warning: missing terminating ' character [-Winvalid-pp-token]
unterminated char literal.c:16:11: warning: empty character constant [-Winvalid-pp-token]
unterminated char literal.c:17:14: warning: empty character constant [-Winvalid-pp-token]
unterminated char literal.c:18:14: warning: missing terminating ' character [-Winvalid-pp-token]
unterminated char literal.c:20:10: warning: empty character constant [-Winvalid-pp-token]
unterminated char literal.c:21:10: warning: missing terminating ' character [-Winvalid-pp-token]
unterminated char literal.c:20:10: error: empty character constant
unterminated char literal.c:21:10: error: missing terminating ' character
unterminated char literal.c:21:11: error: expected ';' before end of file
*/

#define A 'b // #warning@11: missing terminating ' character [-Winvalid-pp-token]
#define B '' // #warning@11: empty character constant [-Winvalid-pp-token]
#define C(X) '' // #warning@14: empty character constant [-Winvalid-pp-token]
#define D(X) 'A // #warning@14: missing terminating ' character [-Winvalid-pp-token]

char c = u8''; // #warning@10: empty character constant [-Winvalid-pp-token] // #error@10: empty character constant
char d = ' // #warning@10: missing terminating ' character [-Winvalid-pp-token] // #error@10: missing terminating ' character // #error@11: expected ';' before end of file