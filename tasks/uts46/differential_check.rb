#!/usr/bin/env ruby
# Differential check: Addressable::IDNA::UTS46 vs Node's domainToASCII
# (ICU UTS 46, WHATWG URL semantics) for every code point assigned in
# Unicode 15.1 or earlier.
#
# Options are matched to WHATWG URL processing: nontransitional, STD3 off,
# no hyphen check, no DNS-length check.  Bidi is disabled on our side
# because Ada implements a simplified bidi rule that deviates from
# RFC 5893 (verified separately against the RFC text).  Code points whose
# mapping contains a WHATWG "forbidden domain code point" are skipped,
# since WHATWG rejects the result for reasons outside UTS 46.
#
# Usage: ruby tasks/uts46/differential_check.rb

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "addressable/idna"
require "set"

ADA = File.expand_path("../../tmp/uts46/ada_sweep2.txt", __dir__)
WHATWG_FORBIDDEN = [0x20, 0x23, 0x25, 0x2F, 0x3A, 0x3C, 0x3E, 0x3F, 0x40,
  0x5B, 0x5C, 0x5D, 0x5E, 0x7C].to_set

ALL_CHARS = ((0..0xD7FF).to_a + (0xE000..0x10FFFF).to_a).pack("U*")
ASSIGNED_15_1 = {}
ALL_CHARS.scan(/\p{age=15.1}/) { |ch| ASSIGNED_15_1[ch.ord] = true }

def my_ascii(domain)
  Addressable::IDNA::UTS46.to_ascii(
    domain,
    use_std3_rules: false,
    check_hyphens: false,
    verify_dns_length: false,
    check_bidi: false
  )
rescue Addressable::IDNA::UTS46::Error
  nil
end

def forbidden?(string)
  string && string.unpack("U*").any? { |c| WHATWG_FORBIDDEN.include?(c) }
end

mismatches = []
skipped_forbidden = 0
checked = 0

File.foreach(ADA) do |line|
  cp_s, p1, p2 = line.split
  cp = cp_s.to_i(16)
  next unless ASSIGNED_15_1[cp]
  ch = [cp].pack("U")
  d1 = "q#{ch}q.com"
  d2 = "#{ch}.com"
  m1 = my_ascii(d1)
  m2 = my_ascii(d2)
  if forbidden?(m1) || forbidden?(m2)
    skipped_forbidden += 1
    next
  end
  checked += 1
  if p1 != "-"
    mismatches << [cp, "P1", p1, m1] if m1 != p1
  elsif p2 != "-"
    mismatches << [cp, "P2", p2, m2] if m2 != p2
  else
    mismatches << [cp, "P1", nil, m1] if m1
    mismatches << [cp, "P2", nil, m2] if m2
  end
end

mismatches.first(40).each do |cp, probe, ada, mine|
  puts format("U+%04X %s ada=%s mine=%s", cp, probe, ada.inspect, mine.inspect)
end
puts "checked=#{checked} skipped_forbidden=#{skipped_forbidden} mismatches=#{mismatches.length}"
exit(mismatches.empty? ? 0 : 1)

