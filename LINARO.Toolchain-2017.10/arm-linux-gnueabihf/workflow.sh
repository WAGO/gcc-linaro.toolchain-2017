#!/usr/bin/env bash

set -e

TOOLCHAIN_CHECKOUT_USE_PROXY="${TOOLCHAIN_CHECKOUT_USE_PROXY:-}"
TOOLCHAIN_TARGET_MARCH="${TOOLCHAIN_TARGET_MARCH:-arm-linux-gnueabihf}"
TOOLCHAIN_INSTALL_DIR="${TOOLCHAIN_INSTALL_DIR:-LINARO.Toolchain-2017.10}"
TOOLCHAIN_MANIFEST="$(readlink -f "${TOOLCHAIN_MANIFEST:-gcc-linaro-arm-linux-gnueabihf-manifest.txt}")"
TOOLCHAIN_ABE_REVISION="${TOOLCHAIN_ABE_REVISION:-a64e7b393c1181cfad5e9a30f75b83bbc317838b}"
TOOLCHAIN_ABE_URL="${TOOLCHAIN_ABE_URL:-https://git.linaro.org/toolchain/abe.git}"
TOOLCHAIN_BUILDDIR="${TOOLCHAIN_BUILDDIR:-build-linaro}"
TOOLCHAIN_TESTLOGDIR="${TOOLCHAIN_TESTRESULTDIR:-test-logs}"
TOOLCHAIN_TESTRESULTDIR="${TOOLCHAIN_TESTRESULTDIR:-test-results}"
TOOLCHAIN_DEJAGNU2JUNIT="${TOOLCHAIN_DEJAGNU2JUNIT:-/workspace/dejagnu2junit/main.py}"
TOOLCHAIN_LIBC="${TOOLCHAIN_LIBC:-glibc}"
TOOLCHAIN_ARCHIVE="${TOOLCHAIN_ARCHIVE:-gcc-5.5.0-linaro-2017.10-arm-linux-gnueabihf.tar.gz}"
GIT="${GIT:-git}"

TEMP_WGETRC="$(mktemp -t '.wgetrc_XXXXXXXXXX')"

disable_proxy() {
  unset http_proxy
  unset https_proxy
}

setup_wgetrc() {
  export WGETRC="$TEMP_WGETRC"
  
  echo > "$WGETRC"
  
  if [[ -n "$HTTP_USERNAME" ]]; then
    echo "http_user=$HTTP_USERNAME" >> "$WGETRC"
  fi
  if [[ -n "$HTTP_PASSWORD" ]]; then
    echo "http_passwd=$HTTP_PASSWORD" >> "$WGETRC"
  fi
}

configure() {
  local builddir="${1:-$TOOLCHAIN_BUILDDIR}"
  local abedir="$PWD/abe"
  ( cd "$builddir" && "$abedir/configure" )
}

checkout() {
  local builddir="${1:-$TOOLCHAIN_BUILDDIR}"
  local manifest="${2:-$TOOLCHAIN_MANIFEST}"
  local abe_url="${3:-$TOOLCHAIN_ABE_URL}"
  local abe_revision="${4:-$TOOLCHAIN_ABE_REVISION}"

  local abedir="$PWD/abe"
  
  if [[ -z "$TOOLCHAIN_CHECKOUT_USE_PROXY" ]]; then
    disable_proxy
  fi
  
  if [[ ! -d abe ]]; then
    "$GIT" clone "$abe_url" abe || return $?
  fi

  ( cd "$abedir" && "$GIT" checkout "$abe_revision" ) || return $?
  
  mkdir -p "$builddir"
  
  setup_wgetrc "$builddir/wgetrc"

  configure "$builddir" || return $?
  
  (    cd "$builddir" \
    && "$abedir/abe.sh" \
          --manifest "$manifest" \
          --set libc="$TOOLCHAIN_LIBC" \
          --checkout all )
}

build() {
  local builddir="${1:-$TOOLCHAIN_BUILDDIR}"
  local manifest="${2:-$TOOLCHAIN_MANIFEST}"
  local abedir="$PWD/abe"

  (    cd "$builddir" \
    && "$abedir/abe.sh" \
          --manifest "$manifest" \
          --set libc="$TOOLCHAIN_LIBC" \
          --disable update \
          --build all )
}

checkbinfmt() {
  local sysroot=$1
  local builddir="${2:-$TOOLCHAIN_BUILDDIR}"
  local gcc="${3:-$(find "$builddir" -type f -name "$TOOLCHAIN_TARGET_MARCH-gcc")}"
  local binfile="${4:-$(mktemp /tmp/binfmt-test.XXXXXX)}"
  
  local output

  # shellcheck disable=SC1117
  "$gcc" -xc -o "$binfile" - <<EOF
    #include <stdio.h>
  
    int main(void){
       printf("Hello\n");
       return 0;
    }
EOF
  
  # shellcheck disable=SC2030
  output="$(export QEMU_LD_PREFIX="$sysroot"; "$binfile")"
  test "${output}" = 'Hello'
}

collect_logs() {
  local builddir="${1:-$TOOLCHAIN_BUILDDIR}"
  local logdir="${2:-$TOOLCHAIN_TESTLOGDIR}"
  
  mkdir -p "$logdir"
  
  (
    shopt -s globstar nullglob
  
    for file in "$builddir"/**/*.sum; do
      # shellcheck disable=SC2001
      cp -v "$(echo "$file" | sed 's+\.sum$+.log+')" "$logdir"/;
    done
  )
}

convert_logs2junit() {
  local logdir="${1:-$TOOLCHAIN_TESTLOGDIR}"
  local testresultdir="${2:-$TOOLCHAIN_TESTRESULTDIR}"
  local dejagnu2junit="${3:-$TOOLCHAIN_DEJAGNU2JUNIT}"
  
  if [[ -x "$dejagnu2junit" ]]; then
    "$dejagnu2junit" "$logdir"/* --outdir "$testresultdir"
  fi
}

check() {
  local builddir="${1:-$TOOLCHAIN_BUILDDIR}"
  local manifest="${2:-$TOOLCHAIN_MANIFEST}"
  local logdir="${3:-$TOOLCHAIN_TESTLOGDIR}"
  local testresultdir="${4:-$TOOLCHAIN_TESTRESULTDIR}"
  
  local abedir="$PWD/abe"
  local sysroot
  
  sysroot="$(readlink -f "$builddir/builds/sysroot-$TOOLCHAIN_TARGET_MARCH")"
  if [[ ! -d "$sysroot" ]]; then
    echo "error: sysroot=$sysroot does not exist" 1>&2
    return 1
  fi
  
  if ! checkbinfmt "$sysroot" "$builddir"; then
    echo 'error: binfmt is not configured properly' 1>&2
    return 2
  fi

  # shellcheck disable=SC2031
  (    export QEMU_LD_PREFIX="$sysroot"; \
       cd "$builddir" \
    && "$abedir/abe.sh" \
          --manifest "$manifest" \
          --set libc="$TOOLCHAIN_LIBC" \
          --disable update \
          --disable make_docs \
          --disable building \
          --build all \
          --check gcc ) || return $?
  
  collect_logs "$builddir" "$logdir" || return $?
  convert_logs2junit "$logdir" "$testresultdir"
}

package() {
  local builddir="${1:-$TOOLCHAIN_BUILDDIR}"
  local manifest="${2:-$TOOLCHAIN_MANIFEST}"
  local archive="${3:-$TOOLCHAIN_ARCHIVE}"
  local installdir="./$TOOLCHAIN_INSTALL_DIR"
  
  local gcc_installdir="$installdir/$TOOLCHAIN_TARGET_MARCH"
  local sysroot_installdir="$installdir/$TOOLCHAIN_TARGET_MARCH-sysroot"
  local abedir="$PWD/abe"
  
  (    cd "$builddir" \
    && "$abedir/abe.sh" \
          --manifest "$manifest" \
          --set libc="$TOOLCHAIN_LIBC" \
          --disable update \
          --disable make_docs \
          --disable building \
          --build all \
          --tarbin ) || return $?
          
  mkdir -p "$gcc_installdir" "$sysroot_installdir"
  
  local today
  today="$(date +%Y%m%d)"
  
  tar xJf "$builddir/snapshots/"sysroot*"-$today"*"$TOOLCHAIN_TARGET_MARCH".tar.xz -C "$sysroot_installdir" --strip 1 || return $?
  tar xJf "$builddir/snapshots/"gcc*"-$today"*"$TOOLCHAIN_TARGET_MARCH".tar.xz -C "$gcc_installdir" --strip 1 || return $?
  
  tar cavf "$archive" "$installdir"
}

cleanup() {
  rm -rf "./$TOOLCHAIN_INSTALL_DIR"
  rm -f "$TEMP_WGETRC"
}

main() {
  trap cleanup EXIT

  if [[ "$#" -eq 0 ]]; then
    # Note: empty arguments are passed to please shellcheck
    configure "$@" || return $?
    build "$@" || return $?
    package "$@" || return $?
    exit 0
  fi

  local command
  
  # parse command line arguments
  while [[ "$#" -gt 0 ]]; do
    case "$1" in

#      -h|--help|-\?)
#        print_usage
#        exit 0
#        ;;
      
      --use-proxy)
        TOOLCHAIN_CHECKOUT_USE_PROXY=1
        ;;
        
      --checkout)
        command=checkout
        ;;
        
      --build)
        command=build
        ;;
    
      --check)
        command=check
        ;;
        
      --package)
        command=package
        ;;
        
      --configure)
        command=configure
        ;;
      *)
        echo "error: unknown option ${1}" 1>&2
        exit 1
        ;;
    esac
    shift
  done
  
  "$command" "$@"
}

if [[ "$0" == "${BASH_SOURCE[0]}" ]]; then
  main "$@"
fi

