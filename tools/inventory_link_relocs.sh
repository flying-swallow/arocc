#!/usr/bin/env bash
# Inventory relocation types in the host files used by arocc's default Linux link.
set -euo pipefail

usage() { echo "usage: $0 [--cc CC] [--with-libc-a] [--per-file|--summary] [FILE...]" >&2; exit 2; }

cc=${CC:-gcc}
with_libc_a=0
mode=
files=()
while (($#)); do
  case $1 in
    --cc) (($# >= 2)) || usage; cc=$2; [[ -n $cc ]] || usage; shift 2 ;;
    --with-libc-a) with_libc_a=1; shift ;;
    --per-file|--summary) [[ -z $mode || $mode == "$1" ]] || usage; mode=$1; shift ;;
    --) shift; files+=("$@"); break ;;
    -*) usage ;;
    *) files+=("$1"); shift ;;
  esac
done
summary=0
if [[ $mode == --summary ]]; then summary=1; fi

readelf=${READELF:-readelf}
if ! command -v "$readelf" >/dev/null 2>&1; then readelf=llvm-readelf
  command -v "$readelf" >/dev/null 2>&1 || { echo "error: neither readelf nor llvm-readelf is available" >&2; exit 2; }
fi

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/inventory-link-relocs.XXXXXX"); trap 'rm -rf "$tmpdir"' EXIT
manifest=$tmpdir/inputs; records=$tmpdir/records; : >"$manifest"; status=0

add_default() {
  local name=$1 path
  if path=$(LC_ALL=C "$cc" "-print-file-name=$name") && [[ $path == */* && -r $path && -f $path ]]; then
    printf '%s\t%s\n' "$name" "$path" >>"$manifest"
  else
    echo "missing: $name$([[ $name == libc.a ]] && echo ' (optional)')" >&2
    [[ $name == libc.a ]] || status=1
  fi
}

defaults=(Scrt1.o crt1.o rcrt1.o crti.o crtbeginS.o crtbegin.o crtbeginT.o crtendS.o crtend.o crtn.o libc_nonshared.a libgcc.a libgcc_eh.a)
for name in "${defaults[@]}"; do add_default "$name"; done
((with_libc_a == 0)) || add_default libc.a

for file in "${files[@]}"; do
  if [[ -r $file && -f $file ]]; then printf '%s\t%s\n' "$file" "$file" >>"$manifest"
  else echo "missing: $file" >&2; status=1; fi
done

if ! LC_ALL=C awk -F '\t' -v summary="$summary" -v readelf="$readelf" '
  function shq(s,    i,c,q) { q="\047"; for(i=1;i<=length(s);i++) { c=substr(s,i,1); q=q (c=="\047" ? "\047\\\047\047" : c) } return q "\047" }
  {
    n++; names[n]=$1; paths[n]=$2
    arg=paths[n]; if(substr(arg,1,1)=="-") arg="./" arg
    cmd="LC_ALL=C " shq(readelf) " -rW " shq(arg)
    while((cmd | getline line)>0) {
      sub(/^[[:space:]]+/,"",line); nf=split(line,f,/[[:space:]]+/)
      if(nf>=3 && f[1]~/^[[:xdigit:]]+$/ && f[3]~/^R_[A-Z0-9_]+$/) {
        key=n SUBSEP f[3]; if(!(key in counts)) types[n,++type_count[n]]=f[3]; counts[key]++
      }
    }
    if(close(cmd)!=0) { print "readelf failed: " paths[n] > "/dev/stderr"; failed=1 }
    for(j=1;j<=type_count[n];j++) { type=types[n,j]; total[type]+=counts[n SUBSEP type]; nfiles[type]++ }
  }
  END {
    if(!summary) for(i=1;i<=n;i++) {
      printf "%09d\t0\t0\t\t# %s\t%s\n",i,names[i],paths[i]
      if(!type_count[i]) printf "%09d\t1\t0\t(none)\t(none)\t0\n",i
      else for(j=1;j<=type_count[i];j++) { type=types[i,j]; printf "%09d\t1\t0\t%s\t%s\t%d\n",i,type,type,counts[i SUBSEP type] }
    }
    last=n+1; printf "%09d\t2\t0\t\t# TOTAL\n",last
    for(type in total) printf "%09d\t3\t%d\t%s\t%s\t%d\t%d\n",last,total[type],type,type,total[type],nfiles[type]
    exit(failed ? 1 : 0)
  }
' "$manifest" >"$records"; then
  status=1
fi
LC_ALL=C sort -t $'\t' -k1,1n -k2,2n -k3,3nr -k4,4 "$records" | cut -f5-
exit "$status"
