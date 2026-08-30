#!/bin/sh
#
# Asserts, on the instance, that kitchen-hetzner configured it the way the
# suite asked for.
#
# Every check is one `name=value' argument, so a single script covers every
# suite and each suite's kitchen.yml entry reads as a list of the claims it is
# making. A failed check names the thing that broke and exits non-zero, which
# fails the converge and therefore the suite.
#
# This runs as the provisioner rather than a verifier on purpose: it is
# transferred over the driver's own transport and executed on the machine, so
# reaching the instance at all is part of every assertion, and there is no
# verifier licence to satisfy.

set -eu

METADATA="http://169.254.169.254/hetzner/v1/metadata"

failures=0

fail() {
  echo "FAIL: $*" >&2
  failures=$((failures + 1))
}

pass() {
  echo "ok:   $*"
}

# Hetzner's images ship curl, but not uniformly across every generation, so
# fall back rather than failing an assertion for the wrong reason.
fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -sf --max-time 10 "$1"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --timeout=10 "$1"
  else
    echo "neither curl nor wget is installed" >&2
    return 1
  fi
}

# Never fails the script itself: an empty value makes the comparison report
# "expected X, got ''", which says more than a bare non-zero exit would.
metadata() {
  fetch "${METADATA}/$1" 2>/dev/null || echo ""
}

# Expects an exact match, and says what it got when there isn't one. A check
# that only prints "failed" costs a second run to diagnose.
compare() {
  what="$1"
  expected="$2"
  actual="$3"

  if [ "$expected" = "$actual" ]; then
    pass "${what} is ${actual}"
  else
    fail "${what}: expected '${expected}', got '${actual}'"
  fi
}

starts_with() {
  what="$1"
  prefix="$2"
  actual="$3"

  case "$actual" in
    "${prefix}"*) pass "${what} '${actual}' starts with '${prefix}'" ;;
    *) fail "${what}: expected something starting with '${prefix}', got '${actual}'" ;;
  esac
}

os_release() {
  [ -f /etc/os-release ] || { echo ""; return 0; }
  # shellcheck disable=SC1091
  . /etc/os-release
  eval "echo \"\${$1:-}\""
}

# The metadata service is the only thing on the instance that knows what the
# API was asked for, so a suite asserting on a driver option almost always ends
# up here.
check_metadata() {
  ip="$(metadata public-ipv4)"
  if [ -z "$ip" ]; then
    fail "the metadata service reported no public IPv4 address"
  else
    pass "public IPv4 is ${ip}"
  fi

  id="$(metadata instance-id)"
  if [ -z "$id" ]; then
    fail "the metadata service reported no instance id"
  else
    pass "instance id is ${id}"
  fi
}

# Proves the generated keypair made the whole round trip: written locally,
# uploaded to the project, injected by Hetzner, accepted by sshd. The script
# only runs at all because the private half worked, so this confirms it was
# this driver's key and not something already on the image.
check_key() {
  authorized="/root/.ssh/authorized_keys"
  [ -f "$authorized" ] || authorized="$HOME/.ssh/authorized_keys"

  if [ ! -f "$authorized" ]; then
    fail "no authorized_keys file was found"
  elif grep -q "^ssh-rsa " "$authorized"; then
    pass "the injected key is in $(basename "$authorized")"
  else
    fail "authorized_keys has no ssh-rsa entry: $(cut -d' ' -f1 <"$authorized" | sort -u | tr '\n' ' ')"
  fi
}

[ "$#" -gt 0 ] || { echo "usage: assert.sh check=value ..." >&2; exit 64; }

for check in "$@"; do
  name="${check%%=*}"
  value="${check#*=}"

  case "$name" in
    metadata) check_metadata ;;
    key) check_key ;;
    arch) compare "architecture" "$value" "$(uname -m)" ;;
    os) compare "distribution" "$value" "$(os_release ID)" ;;
    # A prefix, not an exact match: point releases move under you (AlmaLinux 9
    # reports 9.6 today), and the thing worth asserting is the major version the
    # platform name asked for.
    os-version) starts_with "os version" "$value" "$(os_release VERSION_ID)" ;;
    hostname) compare "hostname" "$value" "$(metadata hostname)" ;;
    hostname-prefix) starts_with "hostname" "$value" "$(metadata hostname)" ;;
    # `region' is the network zone (eu-central); the location slug the driver
    # was given only shows up as the prefix of the availability zone.
    location) starts_with "availability zone" "$value" "$(metadata availability-zone)" ;;
    file)
      if [ -f "$value" ]; then
        pass "${value} exists"
      else
        fail "${value} does not exist"
      fi
      ;;
    file-contains)
      path="${value%%:*}"
      text="${value#*:}"
      if [ -f "$path" ] && grep -qF "$text" "$path"; then
        pass "${path} contains '${text}'"
      else
        fail "${path} does not contain '${text}'"
      fi
      ;;
    *) fail "unknown check '${name}'" ;;
  esac
done

if [ "$failures" -ne 0 ]; then
  echo "${failures} assertion(s) failed" >&2
  exit 1
fi

echo "all assertions passed"
