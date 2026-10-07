# frozen_string_literal: true

# Generates lib/addressable/idna/uts46_data.rb: the UTS 46 (Unicode IDNA
# Compatibility Processing) data shipped with the gem, pinned to
# Unicode 15.1.0.
#
# Everything is computed offline from data already present on the machine;
# nothing is downloaded and no libidn is used:
#
#   * Ruby's Unicode database (normalization, Age, Default_Ignorable, general
#     categories, scripts, combining classes) -- pins the data to 15.1.
#   * The Python "idna" package's uts46data (a copy of the official
#     IdnaMappingTable) and IDNA2008 data, dumped by
#     extract_idna_package_data.py.
#   * Perl's core Unicode data (Bidi_Class, Joining_Type, ccc=9, case
#     folding), dumped by extract_perl_unicode_data.pl.
#   * A behavioral sweep of every code point through ICU's UTS 46
#     implementation (via Node's url.domainToASCII), produced by
#     sweep_icu.js, used as a whole-table cross-check.
#
# Code points assigned after Unicode 15.1 are forced to "disallowed"; IDNA
# status is stable for already-assigned code points, so the result matches
# the Unicode 15.1.0 IdnaMappingTable.
#
# Usage:
#   mkdir -p tmp/uts46
#   python3 tasks/uts46/extract_idna_package_data.py tmp/uts46/py_dump.json
#   perl tasks/uts46/extract_perl_unicode_data.pl tmp/uts46
#   node tasks/uts46/sweep_icu.js tmp/uts46/icu_sweep.txt
#   ruby tasks/uts46/generate_uts46_data.rb

require "json"
require "unicode_normalize/tables"
require "set"

UNICODE_VERSION = "15.1.0"
DUMP_DIR = File.expand_path("../../tmp/uts46", __dir__)
OUTPUT = File.expand_path("../../lib/addressable/idna/uts46_data.rb", __dir__)
MAX_CP = 0x10FFFF

STATUS = {
  valid: 0,
  ignored: 1,
  mapped: 2,
  deviation: 3,
  disallowed: 4,
  disallowed_STD3_valid: 5,
  disallowed_STD3_mapped: 6
}
STATUS_NAMES = STATUS.invert

# UTS #46 exception characters.
DEVIATIONS = {
  0x00DF => "ss",
  0x03C2 => [0x03C3].pack("U"),
  0x200C => "",
  0x200D => ""
}
DOT_LIKE = { 0x3002 => ".", 0xFF0E => ".", 0xFF61 => "." }

# Default_Ignorable code points that are nevertheless "disallowed" in the
# IdnaMappingTable (bidi controls, interlinear annotation and tag
# characters).
DI_DISALLOWED = [
  0x061C, 0x200E, 0x200F, *(0x202A..0x202E), *(0x2066..0x2069),
  *(0xFFF9..0xFFFB), 0xE0001, *(0xE0020..0xE007F)
].to_set

# Cherokee is a documented UTS 46 exception: the original (uppercase)
# letters stay valid and the lowercase letters added in Unicode 8.0 map
# to them, preserving IDNA2003 registrations.
CHEROKEE_VALID = (0x13A0..0x13F5)

# "Inappropriate for plain text" characters (RFC 3454 C.6) that the
# IdnaMappingTable marks disallowed even though they are assigned symbols.
DISALLOWED_INAPPROPRIATE = [*(0x2FF0..0x2FFF), 0x31EF, 0xFFFC, 0xFFFD].to_set

def cherokee_mapping(cp)
  if (0x13F8..0x13FD).cover?(cp)
    [cp - 8].pack("U")
  elsif (0xAB70..0xABBF).cover?(cp)
    [cp - 0x97D0].pack("U")
  end
end

# ---------------------------------------------------------------------------
# Load dumps
# ---------------------------------------------------------------------------
py = JSON.parse(File.read(File.join(DUMP_DIR, "py_dump.json")))
PY_UTS46 = py["uts46"].transform_keys(&:to_i)

def load_ranges(file)
  File.readlines(File.join(DUMP_DIR, file)).map(&:split)
end

PERL_BIDI = load_ranges("perl_bidi.txt").map { |c, s, e| [c, s.to_i, e.to_i] }
PERL_JT = load_ranges("perl_jt.txt").map { |c, s, e| [c, s.to_i, e.to_i] }
PERL_CCC9 = load_ranges("perl_ccc9.txt").map { |s, e| [s.to_i, e.to_i] }
PERL_FC = {}
load_ranges("perl_casefolds.txt").each do |cp, _simple, *full|
  next if full.empty? || full[0] == "-"
  PERL_FC[cp.to_i(16)] = full.map { |c| c.to_i(16) }.pack("U*")
end
# U+1E9E is a documented special case: the official table maps it to U+00DF
# even though full case folding would give "ss".
PERL_FC[0x1E9E] = [0x00DF].pack("U")

ICU = {}
File.readlines(File.join(DUMP_DIR, "icu_sweep.txt")).each do |line|
  cp_s, status, *rest = line.split
  flags = rest.last&.include?("only") ? rest.pop.split(",") : []
  ICU[cp_s.to_i(16)] = [status, rest.join(" "), flags]
end

# ---------------------------------------------------------------------------
# Ruby Unicode property sets
# ---------------------------------------------------------------------------
ALL_CHARS = ((0..0xD7FF).to_a + (0xE000..MAX_CP).to_a).pack("U*")

def codepoints_matching(regex)
  result = {}
  ALL_CHARS.scan(regex) { |char| result[char.ord] = true }
  result
end

puts "computing Unicode property sets..."
ASSIGNED_15_1 = codepoints_matching(/\p{age=15.1}/)
ASSIGNED_13_0 = codepoints_matching(/\p{age=13.0}/)
DEFAULT_IGNORABLE = codepoints_matching(/\p{Default_Ignorable_Code_Point}/)
GC_MN = codepoints_matching(/\p{Mn}/)
GC_MC = codepoints_matching(/\p{Mc}/)
GC_ME = codepoints_matching(/\p{Me}/)
GC_MARK = GC_MN.merge(GC_MC).merge(GC_ME)
GC_DISALLOWED = %w[Cc Cf Zl Zp Zs Co Cs].map { |g| codepoints_matching(/\p{#{g}}/) }.reduce(:merge)
GC_NONCHARACTER = codepoints_matching(/\p{Noncharacter_Code_Point}/)
GC_CF = codepoints_matching(/\p{Cf}/)
SC_ARABIC = codepoints_matching(/\p{Arabic}/)
SC_SYRIAC = codepoints_matching(/\p{Syriac}/)
SC_OLD_UYGHUR = codepoints_matching(/\p{Old_Uyghur}/)

def casefold(char)
  cp = char.ord
  if ASSIGNED_13_0[cp]
    PERL_FC[cp] || char
  else
    char.downcase
  end
end

def nfkc_casefold(char)
  folded = char.unicode_normalize(:nfkc).each_char.map { |c| casefold(c) }.join
  folded.unicode_normalize(:nfkc)
end

# ---------------------------------------------------------------------------
# Derive the UTS 46 status of every code point
# ---------------------------------------------------------------------------
puts "deriving UTS 46 statuses..."
status = Array.new(MAX_CP + 1, STATUS[:disallowed])
mappings = {}

(0..MAX_CP).each do |cp|
  if DEVIATIONS.key?(cp)
    status[cp] = STATUS[:deviation]
    mappings[cp] = DEVIATIONS[cp]
    next
  end
  if DOT_LIKE.key?(cp)
    status[cp] = STATUS[:mapped]
    mappings[cp] = DOT_LIKE[cp]
    next
  end
  if CHEROKEE_VALID.cover?(cp)
    status[cp] = STATUS[:valid]
    next
  end
  if (cm = cherokee_mapping(cp))
    status[cp] = STATUS[:mapped]
    mappings[cp] = cm
    next
  end
  if cp < 0x80
    chr = cp.chr
    if chr.match?(/\A[a-z0-9.\-]\z/)
      status[cp] = STATUS[:valid]
    elsif chr.match?(/\A[A-Z]\z/)
      status[cp] = STATUS[:mapped]
      mappings[cp] = chr.downcase
    else
      status[cp] = STATUS[:disallowed_STD3_valid]
    end
    next
  end
  unless ASSIGNED_15_1[cp]
    status[cp] = STATUS[:disallowed]
    next
  end
  if DEFAULT_IGNORABLE[cp]
    status[cp] = DI_DISALLOWED.include?(cp) ? STATUS[:disallowed] : STATUS[:ignored]
    next
  end
  if DISALLOWED_INAPPROPRIATE.include?(cp)
    status[cp] = STATUS[:disallowed]
    next
  end
  char = [cp].pack("U")
  folded = nfkc_casefold(char)
  if folded != char
    cps = folded.unpack("U*")
    status[cp] =
      if cps.include?(0x2E) || cps.any? { |c| DOT_LIKE.key?(c) }
        # A mapping may not produce the label separator.
        STATUS[:disallowed]
      elsif cps.length == 1 && cps[0] < 0x80 &&
          status[cps[0]] == STATUS[:disallowed_STD3_valid]
        STATUS[:disallowed_STD3_mapped]
      else
        STATUS[:mapped]
      end
    mappings[cp] = folded unless status[cp] == STATUS[:disallowed]
    next
  end
  if GC_DISALLOWED[cp] || GC_NONCHARACTER[cp]
    status[cp] = STATUS[:disallowed]
  else
    status[cp] = STATUS[:valid]
  end
end

# ---------------------------------------------------------------------------
# Cross-check 1: the idna package's copy of the official IdnaMappingTable
# ---------------------------------------------------------------------------
puts "cross-checking against idna package uts46data..."
COLLAPSE = {
  STATUS[:valid] => "V",
  STATUS[:disallowed_STD3_valid] => "V",
  STATUS[:mapped] => "M",
  STATUS[:disallowed_STD3_mapped] => "M",
  STATUS[:ignored] => "I",
  STATUS[:deviation] => "D",
  STATUS[:disallowed] => "X"
}
mismatches = []
PY_UTS46.each do |cp, (their_status, their_mapping)|
  next unless ASSIGNED_15_1[cp]
  mine = COLLAPSE[status[cp]]
  if mine != their_status
    mismatches << format("  U+%04X mine=%s theirs=%s", cp, STATUS_NAMES[status[cp]], their_status)
    next
  end
  if their_mapping && mappings[cp] != their_mapping
    mismatches << format("  U+%04X mapping mine=%s theirs=%s", cp, mappings[cp].inspect, their_mapping.inspect)
  end
end
if mismatches.any?
  puts "MISMATCHES vs idna package (#{mismatches.length}):"
  puts mismatches.first(60)
  abort "cross-check 1 failed"
end
puts "  ok (#{PY_UTS46.count { |cp, _| ASSIGNED_15_1[cp] }} entries compared)"

# ---------------------------------------------------------------------------
# Cross-check 2: behavioral sweep of ICU's UTS 46 implementation.
#
# ICU (via Node's domainToASCII) runs with WHATWG URL semantics: STD3 rules
# relaxed, no hyphen/length checks, its own bidi quirk, and an extra
# "forbidden domain code point" rejection applied to results.  The sweep
# probes "q<cp>q.com" and "<cp>.com"; we account for those differences.
# ---------------------------------------------------------------------------
puts "cross-checking against ICU sweep..."
WHATWG_FORBIDDEN = [0x20, 0x23, 0x25, 0x2F, 0x3A, 0x3C, 0x3E, 0x3F, 0x40,
  0x5B, 0x5C, 0x5D, 0x5E, 0x7C].to_set
mismatches = []
(0x80..MAX_CP).each do |cp|
  next if (0xD800..0xDFFF).cover?(cp)
  next unless ASSIGNED_15_1[cp]
  icu_status, icu_mapping, = ICU[cp] || ["V", "", []]
  expected =
    case status[cp]
    when STATUS[:valid] then ["V"]
    when STATUS[:ignored] then ["I"]
    when STATUS[:deviation] then (cp == 0x200C || cp == 0x200D) ? ["X"] : ["V"]
    when STATUS[:mapped], STATUS[:disallowed_STD3_mapped]
      target = mappings[cp].unpack("U*")
      target.any? { |t| WHATWG_FORBIDDEN.include?(t) } ? ["X"] : ["M", target]
    when STATUS[:disallowed] then ["X"]
    end
  ok =
    case expected[0]
    when "V" then icu_status == "V"
    when "I" then icu_status == "I"
    when "X" then icu_status == "X"
    when "M"
      icu_status == "M" &&
        icu_mapping.split(" ").map { |h| h.to_i(16) } == expected[1]
    end
  unless ok
    mismatches << format(
      "  U+%04X mine=%s %s icu=%s %s",
      cp, STATUS_NAMES[status[cp]], mappings[cp].inspect, icu_status, icu_mapping
    )
  end
end
if mismatches.any?
  puts "MISMATCHES vs ICU sweep (#{mismatches.length}):"
  puts mismatches.first(60)
  abort "cross-check 2 failed"
end
puts "  ok (all age<=15.1 code points compared)"

# ---------------------------------------------------------------------------
# Bidi classes for every code point that can appear in a validated label
# (valid + deviation).  Perl provides Unicode 13.0 data; characters assigned
# in 13.1..15.1 are derived from their script and general category.
# ---------------------------------------------------------------------------
puts "deriving bidi classes..."
perl_bidi_lookup = {}
PERL_BIDI.each do |cls, s, e|
  (s..e).each { |cp| perl_bidi_lookup[cp] = cls }
end

bidi = {}
bidi_supplement = []
(0..MAX_CP).each do |cp|
  next unless status[cp] == STATUS[:valid] || status[cp] == STATUS[:deviation]
  if ASSIGNED_13_0[cp]
    cls = perl_bidi_lookup[cp] or abort format("no bidi class for U+%04X", cp)
    bidi[cp] = cls
  else
    cls =
      if GC_MARK[cp]
        "NSM"
      elsif SC_OLD_UYGHUR[cp]
        "R"
      elsif SC_ARABIC[cp] || SC_SYRIAC[cp]
        "AL"
      else
        "L"
      end
    bidi[cp] = cls
    bidi_supplement << [cp, cls]
  end
end
puts "  bidi supplement (post-13.0): #{bidi_supplement.length} code points"
File.write(
  File.join(DUMP_DIR, "bidi_supplement.txt"),
  bidi_supplement.map { |cp, cls| format("U+%04X %s", cp, cls) }.join("\n") + "\n"
)

# ---------------------------------------------------------------------------
# Joining types (ContextJ) and viramas, cross-checked against Perl
# ---------------------------------------------------------------------------
puts "deriving joining types..."
perl_jt_lookup = {}
PERL_JT.each do |cls, s, e|
  (s..e).each { |cp| perl_jt_lookup[cp] = cls }
end

PY_JOINING = py["joining"].transform_keys(&:to_i)
joining = {}
# Perl's Unicode 13.0 data is authoritative (it includes the explicit
# ArabicShaping.txt entries as well as the Mn/Me/Cf => Transparent default).
perl_jt_lookup.each do |cp, cls|
  next unless ASSIGNED_13_0[cp]
  joining[cp] = cls if %w[L R D T].include?(cls)
end
# For characters assigned after 13.0: explicit L/R/D from the idna package,
# and the default rule (Mn/Me/Cf => Transparent, except ZWNJ/ZWJ).
PY_JOINING.each do |cp, cls|
  next unless ASSIGNED_15_1[cp] && !ASSIGNED_13_0[cp]
  joining[cp] = cls if %w[L R D].include?(cls)
end
(0..MAX_CP).each do |cp|
  next unless ASSIGNED_15_1[cp] && !ASSIGNED_13_0[cp]
  next if cp == 0x200C || cp == 0x200D
  next unless GC_MN[cp] || GC_ME[cp] || GC_CF[cp]
  joining[cp] ||= "T"
end
jt_mismatch = []
joining.each do |cp, cls|
  if ASSIGNED_13_0[cp]
    perl_cls = perl_jt_lookup[cp]
    jt_mismatch << [cp, cls, perl_cls] if perl_cls != cls
  end
end
perl_jt_lookup.each do |cp, cls|
  next unless %w[L R D T].include?(cls)
  next unless ASSIGNED_13_0[cp]
  jt_mismatch << [cp, joining[cp], cls] if joining[cp] != cls
end
if jt_mismatch.any?
  puts "JOINING TYPE MISMATCHES vs perl:"
  jt_mismatch.first(50).each do |cp, mine, perl|
    puts format("  U+%04X mine=%s perl=%s", cp, mine.inspect, perl.inspect)
  end
  abort "cross-check failed"
end
puts "  ok (#{joining.length} L/R/D/T code points)"

virama = []
UnicodeNormalize::CLASS_TABLE.each do |char, ccc|
  cp = char.ord
  virama << cp if ccc == 9 && ASSIGNED_15_1[cp]
end
virama.sort!
perl_ccc9 = []
PERL_CCC9.each { |s, e| (s..e).each { |cp| perl_ccc9 << cp } }
ccc9_mine_13 = virama.select { |cp| ASSIGNED_13_0[cp] }
if ccc9_mine_13.sort != perl_ccc9.sort
  abort "ccc=9 mismatch vs perl"
end
puts "  ok (#{virama.length} viramas)"

# ---------------------------------------------------------------------------
# Emit the data file
# ---------------------------------------------------------------------------
puts "writing #{OUTPUT}..."

def rangify(pairs)
  ranges = []
  start = prev = current = nil
  pairs.each do |cp, value|
    if current == value && prev == cp - 1
      prev = cp
      next
    end
    ranges << [start, prev, current] if start
    start = prev = cp
    current = value
  end
  ranges << [start, prev, current] if start
  ranges
end

status_ranges = rangify((0..MAX_CP).map { |cp| [cp, status[cp]] })
bidi_ranges = rangify(bidi.sort.map { |cp, cls| [cp, cls] })
joining_ranges = rangify(joining.sort.map { |cp, cls| [cp, cls] })
mark_ranges = rangify(GC_MARK.keys.select { |cp| ASSIGNED_15_1[cp] }.sort.map { |cp| [cp, true] })

File.open(OUTPUT, "w") do |f|
  f.puts "# frozen_string_literal: true"
  f.puts
  f.puts "# Generated by tasks/uts46/generate_uts46_data.rb -- do not edit."
  f.puts "# UTS 46 (Unicode IDNA Compatibility Processing) data, pinned to"
  f.puts "# Unicode #{UNICODE_VERSION}. Regenerate with: rake idna:uts46_data"
  f.puts
  f.puts "module Addressable"
  f.puts "  module IDNA"
  f.puts "    module UTS46"
  f.puts "      UNICODE_VERSION = #{UNICODE_VERSION.inspect}.freeze"
  f.puts
  f.puts "      STATUS_VALID = 0"
  f.puts "      STATUS_IGNORED = 1"
  f.puts "      STATUS_MAPPED = 2"
  f.puts "      STATUS_DEVIATION = 3"
  f.puts "      STATUS_DISALLOWED = 4"
  f.puts "      STATUS_DISALLOWED_STD3_VALID = 5"
  f.puts "      STATUS_DISALLOWED_STD3_MAPPED = 6"
  f.puts
  f.puts "      BIDI_CLASSES = %i[L R AL EN ES ET AN CS BN ON NSM].freeze"
  f.puts
  f.puts "      JOINING_L = 0"
  f.puts "      JOINING_R = 1"
  f.puts "      JOINING_D = 2"
  f.puts "      JOINING_T = 3"
  f.puts
  f.puts "      STATUS_RANGES = ["
  status_ranges.each do |s, e, st|
    f.puts "        [#{s}, #{e}, #{st}],"
  end
  f.puts "      ].freeze"
  f.puts
  f.puts "      MAPPINGS = {"
  mappings.sort.each do |cp, str|
    f.puts "        #{cp} => #{str.inspect},"
  end
  f.puts "      }.freeze"
  f.puts
  bidi_code = { "L" => 0, "R" => 1, "AL" => 2, "EN" => 3, "ES" => 4,
    "ET" => 5, "AN" => 6, "CS" => 7, "BN" => 8, "ON" => 9, "NSM" => 10 }
  f.puts "      BIDI_RANGES = ["
  bidi_ranges.each do |s, e, cls|
    f.puts "        [#{s}, #{e}, #{bidi_code.fetch(cls)}],"
  end
  f.puts "      ].freeze"
  f.puts
  jt_code = { "L" => 0, "R" => 1, "D" => 2, "T" => 3 }
  f.puts "      JOINING_RANGES = ["
  joining_ranges.each do |s, e, cls|
    f.puts "        [#{s}, #{e}, #{jt_code.fetch(cls)}],"
  end
  f.puts "      ].freeze"
  f.puts
  f.puts "      MARK_RANGES = ["
  mark_ranges.each do |s, e, _|
    f.puts "        [#{s}, #{e}],"
  end
  f.puts "      ].freeze"
  f.puts
  f.puts "      VIRAMA = #{virama.inspect}.freeze"
  f.puts "    end"
  f.puts "  end"
  f.puts "end"
end

counts = Hash.new(0)
status.each { |st| counts[STATUS_NAMES[st]] += 1 }
puts "status counts: #{counts.inspect}"
puts "ranges: status=#{status_ranges.length} bidi=#{bidi_ranges.length} " \
  "joining=#{joining_ranges.length} mark=#{mark_ranges.length} virama=#{virama.length}"
puts "done"
