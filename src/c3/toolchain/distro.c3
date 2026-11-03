// Port of src/aro/Toolchain/Distro.zig: figuring out which Linux distro the
// *host* runs (release files are read at absolute host paths, never under
// the sysroot), gated on the *target* OS being Linux.
// STAGE 0 CONTRACT: types and signatures are fixed; bodies are stubs (agent 23.3).
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
	return GNU; // STUB
}

fn bool Tag.is_redhat(self) => false; // STUB
fn bool Tag.is_open_suse(self) => false; // STUB
fn bool Tag.is_debian(self) => false; // STUB
fn bool Tag.is_ubuntu(self) => false; // STUB
fn bool Tag.is_alpine(self) => false; // STUB
fn bool Tag.is_gentoo(self) => false; // STUB

<* scanForOsRelease (os-release `ID=` line). NO_MATCH = Zig null. *>
fn Tag? scan_for_os_release(String buf)
{
	return NO_MATCH~; // STUB
}

<* scanForLSBRelease (`DISTRIB_CODENAME=` line). NO_MATCH = Zig null. *>
fn Tag? scan_for_lsb_release(String buf)
{
	return NO_MATCH~; // STUB
}

<* scanForRedHat (/etc/redhat-release contents). *>
fn Tag scan_for_red_hat(String buf)
{
	return UNKNOWN; // STUB
}

<* scanForDebian (/etc/debian_version contents). *>
fn Tag scan_for_debian(String buf)
{
	return UNKNOWN; // STUB
}

<*
 Distro.detect: UNKNOWN unless env.target is Linux; otherwise tries
 /etc/os-release (then /usr/lib/os-release), /etc/lsb-release,
 /etc/redhat-release, /etc/debian_version, /etc/gentoo-release, in Zig order.
*>
fn Tag detect(Env* env)
{
	return UNKNOWN; // STUB
}
