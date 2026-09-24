#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2025-2026 Kaptain contributors (Fred Cooke)
#
# hash_base32 <file> <length> # the file's SHA-256 as Base32, truncated to <length> output chars.
#
# This function produces Base32 in RFC 4648 section 6 style, but with the
# letters lower cased for Kubernetes naming compatibility. Used as a suffix on
# Kubernetes resource names when the resource opts into having its contents
# processed for this purpose.
#
# The default Base32 formatted checksum is 52 chars long and is intended to be
# overridden in use by the consuming code. Typical values for real world use
# are in the 4 to 12 range.
#
# Chosen by benchmark, 10k calls each:
#
# hash (macOS, 4867 B file):
#   * cksum                 2.14 ms
#   * sha1sum               2.46 ms
#   * md5sum                2.52 ms
#   * sha256sum             2.55 ms   <- chosen (portable name + GNU output)
#   * sha512sum             2.61 ms
#   * openssl (LibreSSL)    2.71 ms   <- system /usr/bin, fast
#   * openssl (OpenSSL 3)   5.83 ms   <- brew, slower
#   * shasum (Perl)        13.50 ms
#
# encode (Linux):
#   * bash (in-process)     0.20 ms   <- chosen
#   * awk                   1.35 ms
#   * perl                  1.95 ms
#   * python               17.90 ms

hash_base32() {
  # Arguments
  local file="${1}"
  local length=${2:-52}

  # Constant data
  local alpha="abcdefghijklmnopqrstuvwxyz234567"
  local H=(0000 0001 0010 0011 0100 0101 0110 0111 1000 1001 1010 1011 1100 1101 1110 1111)

  # Capture the hex SHA-256 of the file
  local hex
  hex=$(sha256sum "${file}") || return 1
  hex=${hex%% *}

  # Expand hex nibbles to bits, stopping once we have enough for <length>
  # chars, or the digest runs out (which saturates at the full hash)
  local i
  local bits=""
  for (( i = 0; i < ${#hex} && ${#bits} < length * 5; i++ )); do
    bits+=${H[$((16#${hex:i:1}))]}
  done

  # Take 5 bits at a time as a value 0-31 and index the alphabet; zero-pad a
  # short final group; stop at <length> chars or when the bits run out
  local j
  local g
  local out=""
  for (( j = 0; ${#out} < length && j < ${#bits}; j += 5 )); do
    g=${bits:j:5}; while [ ${#g} -lt 5 ]; do g+=0; done
    out+=${alpha:$((2#$g)):1}
  done
  printf '%s' "$out"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then hash_base32 "$@"; echo; fi
