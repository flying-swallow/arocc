// Port of src/aro/Toolchain/Distro.zig: figuring out which Linux distro the
// *host* runs (release files are read at absolute host paths, never under
// the sysroot), gated on the *target* OS being Linux.
module aro::toolchain::distro;
import aro::toolchain::discovery, aro::target;

<* Distro.MAX_BYTES: release files are read into a buffer this large. *>
const usz MAX_BYTES = 1024;

<* Value for linker `--hash-style=` argument. `name` is the Zig tag name. *>
enum HashStyle : char (String name)
{
	BOTH { "both" },
	GNU { "gnu" },
}

<* Distro.Tag, same order as Zig. *>
enum Tag : char
{
	ALPINE,
	ARCH,
	DEBIAN_LENNY,
	DEBIAN_SQUEEZE,
	DEBIAN_WHEEZY,
	DEBIAN_JESSIE,
	DEBIAN_STRETCH,
	DEBIAN_BUSTER,
	DEBIAN_BULLSEYE,
	DEBIAN_BOOKWORM,
	DEBIAN_TRIXIE,
	EXHERBO,
	RHEL5,
	RHEL6,
	RHEL7,
	FEDORA,
	GENTOO,
	OPEN_SUSE,
	UBUNTU_HARDY,
	UBUNTU_INTREPID,
	UBUNTU_JAUNTY,
	UBUNTU_KARMIC,
	UBUNTU_LUCID,
	UBUNTU_MAVERICK,
	UBUNTU_NATTY,
	UBUNTU_ONEIRIC,
	UBUNTU_PRECISE,
	UBUNTU_QUANTAL,
	UBUNTU_RARING,
	UBUNTU_SAUCY,
	UBUNTU_TRUSTY,
	UBUNTU_UTOPIC,
	UBUNTU_VIVID,
	UBUNTU_WILY,
	UBUNTU_XENIAL,
	UBUNTU_YAKKETY,
	UBUNTU_ZESTY,
	UBUNTU_ARTFUL,
	UBUNTU_BIONIC,
	UBUNTU_COSMIC,
	UBUNTU_DISCO,
	UBUNTU_EOAN,
	UBUNTU_FOCAL,
	UBUNTU_GROOVY,
	UBUNTU_HIRSUTE,
	UBUNTU_IMPISH,
	UBUNTU_JAMMY,
	UBUNTU_KINETIC,
	UBUNTU_LUNAR,
	UNKNOWN,
}

<* Returned by the scan_* helpers where Zig returns null. *>
excuse NO_MATCH;

fn HashStyle Tag.get_hash_style(self)
{
	if (self.is_open_suse()) return BOTH;
	switch (self)
	{
		case UBUNTU_LUCID:
		case UBUNTU_JAUNTY:
		case UBUNTU_KARMIC: return BOTH;
		default: return GNU;
	}
}

fn bool Tag.is_redhat(self) => self == FEDORA || self == RHEL5 || self == RHEL6 || self == RHEL7;
fn bool Tag.is_open_suse(self) => self == OPEN_SUSE;
fn bool Tag.is_debian(self) => self >= DEBIAN_LENNY && self <= DEBIAN_TRIXIE;
fn bool Tag.is_ubuntu(self) => self >= UBUNTU_HARDY && self <= UBUNTU_LUNAR;
fn bool Tag.is_alpine(self) => self == ALPINE;
fn bool Tag.is_gentoo(self) => self == GENTOO;

<*
 mem.splitScalar(buf, '\n') iteration: stores the line starting at *pos in
 `line` and advances past the next newline; false once the buffer is used up
 (an empty buffer yields one empty line, like Zig). Lines keep any '\r'.
*>
fn bool next_line(String buf, usz* pos, String* line)
{
	if (*pos > buf.len) return false;
	usz start = *pos;
	usz i = start;
	while (i < buf.len && buf[i] != '\n') i++;
	*line = buf[start:i - start];
	*pos = i + 1;
	return true;
}

<* scanForOsRelease (os-release `ID=` line). NO_MATCH = Zig null. *>
fn Tag? scan_for_os_release(String buf)
{
	usz pos = 0;
	String line;
	while (next_line(buf, &pos, &line))
	{
		if (line.starts_with("ID="))
		{
			String rest = line[3..];
			if (rest == "alpine") return ALPINE;
			if (rest == "fedora") return FEDORA;
			if (rest == "gentoo") return GENTOO;
			if (rest == "arch") return ARCH;
			if (rest == "sles") return OPEN_SUSE;
			if (rest == "opensuse") return OPEN_SUSE;
			if (rest == "exherbo") return EXHERBO;
		}
	}
	return NO_MATCH~;
}

<* scanForLSBRelease (`DISTRIB_CODENAME=` line). NO_MATCH = Zig null. *>
fn Tag? scan_for_lsb_release(String buf)
{
	usz pos = 0;
	String line;
	while (next_line(buf, &pos, &line))
	{
		if (line.starts_with("DISTRIB_CODENAME="))
		{
			String rest = line[17..];
			if (rest == "hardy") return UBUNTU_HARDY;
			if (rest == "intrepid") return UBUNTU_INTREPID;
			if (rest == "jaunty") return UBUNTU_JAUNTY;
			if (rest == "karmic") return UBUNTU_KARMIC;
			if (rest == "lucid") return UBUNTU_LUCID;
			if (rest == "maverick") return UBUNTU_MAVERICK;
			if (rest == "natty") return UBUNTU_NATTY;
			if (rest == "oneiric") return UBUNTU_ONEIRIC;
			if (rest == "precise") return UBUNTU_PRECISE;
			if (rest == "quantal") return UBUNTU_QUANTAL;
			if (rest == "raring") return UBUNTU_RARING;
			if (rest == "saucy") return UBUNTU_SAUCY;
			if (rest == "trusty") return UBUNTU_TRUSTY;
			if (rest == "utopic") return UBUNTU_UTOPIC;
			if (rest == "vivid") return UBUNTU_VIVID;
			if (rest == "wily") return UBUNTU_WILY;
			if (rest == "xenial") return UBUNTU_XENIAL;
			if (rest == "yakkety") return UBUNTU_YAKKETY;
			if (rest == "zesty") return UBUNTU_ZESTY;
			if (rest == "artful") return UBUNTU_ARTFUL;
			if (rest == "bionic") return UBUNTU_BIONIC;
			if (rest == "cosmic") return UBUNTU_COSMIC;
			if (rest == "disco") return UBUNTU_DISCO;
			if (rest == "eoan") return UBUNTU_EOAN;
			if (rest == "focal") return UBUNTU_FOCAL;
			if (rest == "groovy") return UBUNTU_GROOVY;
			if (rest == "hirsute") return UBUNTU_HIRSUTE;
			if (rest == "impish") return UBUNTU_IMPISH;
			if (rest == "jammy") return UBUNTU_JAMMY;
			if (rest == "kinetic") return UBUNTU_KINETIC;
			if (rest == "lunar") return UBUNTU_LUNAR;
		}
	}
	return NO_MATCH~;
}

<* mem.findPos(u8, buf, 0, needle) != null *>
fn bool contains(String buf, String needle)
{
	if (needle.len > buf.len) return false;
	for (usz i = 0; i + needle.len <= buf.len; i++)
	{
		if (buf[i:needle.len] == needle) return true;
	}
	return false;
}

<* scanForRedHat (redhat-release contents). *>
fn Tag scan_for_red_hat(String buf)
{
	if (buf.starts_with("Fedora release")) return FEDORA;
	if (buf.starts_with("Red Hat Enterprise Linux") || buf.starts_with("CentOS") || buf.starts_with("Scientific Linux"))
	{
		if (contains(buf, "release 7")) return RHEL7;
		if (contains(buf, "release 6")) return RHEL6;
		if (contains(buf, "release 5")) return RHEL5;
	}
	return UNKNOWN;
}

<*
 std.fmt.parseInt(u8, s, 10): optional sign ('-' only for a zero value, which
 Zig accepts as 0), decimal digits with '_' only between digits, value <= 255.
*>
fn bool parse_u8(String s, char* out)
{
	if (s.len == 0) return false;
	usz i = 0;
	bool neg = false;
	if (s[0] == '+' || s[0] == '-')
	{
		neg = s[0] == '-';
		i = 1;
		if (s.len == 1) return false;
	}
	uint v = 0;
	bool prev_underscore = true;
	for (; i < s.len; i++)
	{
		char c = s[i];
		if (c == '_')
		{
			if (prev_underscore) return false;
			prev_underscore = true;
			continue;
		}
		if (c < '0' || c > '9') return false;
		prev_underscore = false;
		v = v * 10 + (c - '0');
		if (v > 255) return false;
	}
	if (prev_underscore) return false;
	if (neg && v != 0) return false;
	*out = (char)v;
	return true;
}

<*
 scanForDebian (debian_version contents). Note the first '.'-separated piece
 keeps any newline, so "13\n" is not a number and falls through to the
 codename check (UNKNOWN), exactly like Zig.
*>
fn Tag scan_for_debian(String buf)
{
	sz dot = buf.len;
	foreach (i, c : buf)
	{
		if (c == '.')
		{
			dot = i;
			break;
		}
	}
	char major;
	if (parse_u8(buf[:dot], &major))
	{
		switch (major)
		{
			case 5: return DEBIAN_LENNY;
			case 6: return DEBIAN_SQUEEZE;
			case 7: return DEBIAN_WHEEZY;
			case 8: return DEBIAN_JESSIE;
			case 9: return DEBIAN_STRETCH;
			case 10: return DEBIAN_BUSTER;
			case 11: return DEBIAN_BULLSEYE;
			case 12: return DEBIAN_BOOKWORM;
			case 13: return DEBIAN_TRIXIE;
			default: return UNKNOWN;
		}
	}
	usz pos = 0;
	String name;
	next_line(buf, &pos, &name);
	if (name == "squeeze/sid") return DEBIAN_SQUEEZE;
	if (name == "wheezy/sid") return DEBIAN_WHEEZY;
	if (name == "jessie/sid") return DEBIAN_JESSIE;
	if (name == "stretch/sid") return DEBIAN_STRETCH;
	if (name == "buster/sid") return DEBIAN_BUSTER;
	if (name == "bullseye/sid") return DEBIAN_BULLSEYE;
	if (name == "bookworm/sid") return DEBIAN_BOOKWORM;
	return UNKNOWN;
}

const String OS_RELEASE = "/etc/os-release";
const String USR_LIB_OS_RELEASE = "/usr/lib/os-release";
const String LSB_RELEASE = "/etc/lsb-release";
const String REDHAT_RELEASE = "/etc/redhat-release";
const String DEBIAN_VERSION = "/etc/debian_version";
const String GENTOO_RELEASE = "/etc/gentoo-release";

fn Tag? detect_os_release(Env* env)
{
	char[MAX_BYTES] buf;
	char[]? data = env.read_file(OS_RELEASE, &buf);
	if (catch data) data = env.read_file(USR_LIB_OS_RELEASE, &buf);
	if (catch data) return NO_MATCH~;
	return scan_for_os_release((String)data);
}

fn Tag? detect_lsb_release(Env* env)
{
	char[MAX_BYTES] buf;
	char[]? data = env.read_file(LSB_RELEASE, &buf);
	if (catch data) return NO_MATCH~;
	return scan_for_lsb_release((String)data);
}

fn Tag? detect_redhat(Env* env)
{
	char[MAX_BYTES] buf;
	char[]? data = env.read_file(REDHAT_RELEASE, &buf);
	if (catch data) return NO_MATCH~;
	return scan_for_red_hat((String)data);
}

fn Tag? detect_debian(Env* env)
{
	char[MAX_BYTES] buf;
	char[]? data = env.read_file(DEBIAN_VERSION, &buf);
	if (catch data) return NO_MATCH~;
	return scan_for_debian((String)data);
}

<*
 Distro.detect: UNKNOWN unless env.target is Linux; otherwise tries the
 os-release files, lsb-release, redhat-release, debian_version and
 gentoo-release, in Zig order. These are the host's files at absolute paths,
 never looked up under env.sysroot. A redhat-release/debian_version that
 exists but is not recognized yields UNKNOWN and stops the search (Zig
 returns the non-null `.unknown`); only the first MAX_BYTES bytes are read.
*>
fn Tag detect(Env* env)
{
	if (env.target.os.tag != LINUX) return UNKNOWN;
	if (try tag = detect_os_release(env)) return tag;
	if (try tag = detect_lsb_release(env)) return tag;
	if (try tag = detect_redhat(env)) return tag;
	if (try tag = detect_debian(env)) return tag;
	if (env.exists(GENTOO_RELEASE)) return GENTOO;
	return UNKNOWN;
}
