// Terminal output shared by every frontend and the backend dumpers: the
// no_color / escape_codes subset of Zig std.Io.Terminal.
module aro::terminal;
import std::io;

enum ColorMode : char
{
	NO_COLOR,
	ESCAPE_CODES,
}

struct Terminal
{
	OutStream writer;
	ColorMode mode;
}

fn void? Terminal.set_color(self, String color)
{
	if (self.mode == NO_COLOR) return;
	io::write_all(self.writer, color)!;
}

fn void? Terminal.write(self, String s)
{
	if (s.len) io::write_all(self.writer, s)!;
}
