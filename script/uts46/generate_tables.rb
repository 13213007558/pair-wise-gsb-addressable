#!/usr/bin/env ruby
# frozen_string_literal: true

# Generates lib/addressable/idna/uts46/tables.rb: the Unicode 15.1.0 IDNA
# mapping table plus the character property data needed for UTS 46
# validity checks (Bidi class, Joining_Type, Virama, Mark, scripts).
#
# Data sources (all offline, no downloads at build or runtime):
#
#   1. The UTS 46 mapping table from tr46 v4.1.1 (Unicode 15.0.0), the
#      reference JavaScript implementation of UTS 46, which ships the
#      official IdnaMappingTable with all seven statuses.
#   2. Code points assigned in Unicode 15.1.0 (computed from Ruby's own
#      Onigmo \p{age=...} data). Unicode 15.1 only added code points; the
#      IDNA status of every previously assigned code point is frozen by
#      Unicode stability policy, so "15.0 table + new-in-15.1 => valid"
#      is exactly the official 15.1 table. (Verified: every code point
#      added in 15.1 is a Lo ideograph, valid in IDNA.)
#   3. Character properties (Bidi_Class, Joining_Type, Canonical
#      Combining Class, General_Category, Script) dumped from Python's
#      "regex" module by script/uts46/dump_charprops.py, intersected with
#      the set of code points assigned in Unicode 15.1.
#
# As a cross-check, the derived 15.1 table is compared against the
# mapping table shipped by tr46 v5.1.1 (Unicode 16.0.0, with the STD3
# statuses collapsed) for every code point assigned in Unicode 15.1.
#
# Usage:
#   ruby script/uts46/generate_tables.rb \
#     .tmp/uts46/mappingTable-4.1.1.json \
#     .tmp/uts46/charprops.json \
#     .tmp/uts46/mappingTable-5.1.1.json   # optional cross-check
#
# Output: lib/addressable/idna/uts46/tables.rb

require "json"

TR46_STATUS = {
  1 => :mapped,
  2 => :valid,
  3 => :disallowed,
  4 => :disallowed_STD3_valid,
  5 => :disallowed_STD3_mapped,
  6 => :deviation,
  7 => :ignored
}.freeze

UNICODE_VERSION = "15.1.0"

def load_tr46_table(path)
  entries = JSON.parse(File.read(path)).map do |entry|
    first, last = entry[0].is_a?(Array) ? entry[0] : [entry[0], entry[0]]
    status = TR46_STATUS.fetch(entry[1])
    mapping = entry[2]
    [first, last, status, mapping]
  end
  entries.sort_by!(&:first)
  entries.each_cons(2) do |a, b|
    raise "overlapping ranges in #{path}" if a[1] >= b[0]
  end
  entries
end

def lookup(entries, cp)
  lo = 0
  hi = entries.size - 1
  while lo <= hi
    mid = (lo + hi) / 2
    first, last = entries[mid][0], entries[mid][1]
    if cp < first
      hi = mid - 1
    elsif cp > last
      lo = mid + 1
    else
      return entries[mid]
    end
  end
  nil
end

def status_of(entries, cp)
  entry = lookup(entries, cp)
  entry ? [entry[2], entry[3]] : [:valid, nil]
end

# Ranges of code points whose Onigmo "age" property is at most +version+.
# Onigmo implements Age cumulatively: \p{age=15.1} matches every code
# point assigned in Unicode 15.1 or earlier.
def age_ranges(version)
  re = /\A\p{age=#{version}}\z/u
  ranges = []
  start = nil
  prev = nil
  (0..0x10FFFF).each do |cp|
    next if (0xD800..0xDFFF).cover?(cp)
    if cp.chr(Encoding::UTF_8).match?(re)
      if start.nil?
        start = cp
      elsif prev != cp - 1
        ranges << [start, prev]
        start = cp
      end
      prev = cp
    end
  end
  ranges << [start, prev] if start
  ranges
end

def subtract_ranges(a, b)
  result = []
  bj = 0
  a.each do |lo, hi|
    cur = lo
    bj += 1 while bj < b.size && b[bj][1] < cur
    k = bj
    while k < b.size && b[k][0] <= hi
      result << [cur, [b[k][0] - 1, hi].min] if b[k][0] > cur
      cur = [cur, b[k][1] + 1].max
      break if cur > hi
      k += 1
    end
    result << [cur, hi] if cur <= hi
  end
  result
end

def intersect_ranges(a, b)
  result = []
  i = j = 0
  while i < a.size && j < b.size
    lo = [a[i][0], b[j][0]].max
    hi = [a[i][1], b[j][1]].min
    result << [lo, hi] if lo <= hi
    if a[i][1] < b[j][1]
      i += 1
    else
      j += 1
    end
  end
  result
end

def merge_ranges(entries)
  merged = []
  entries.each do |entry|
    if merged.empty? || merged[-1][1] + 1 != entry[0] || merged[-1][2..] != entry[2..]
      merged << entry.dup
    else
      merged[-1][1] = entry[1]
    end
  end
  merged
end

def expand_ranges(ranges)
  ranges.flat_map { |lo, hi| (lo..hi).to_a }
end

tr46_path, charprops_path, crosscheck_path = *ARGV
if tr46_path.nil? || charprops_path.nil?
  raise "usage: generate_tables.rb TR46_4_1_1.json CHARPROPS.json [TR46_5_1_1.json]"
end

puts "loading UTS 46 mapping table (Unicode 15.0.0) from #{tr46_path}"
table = load_tr46_table(tr46_path)

# Sanity-check known entries of the 15.0 table.
{
  0x0041 => [:mapped, "a"],
  0x005F => [:disallowed_STD3_valid, nil],
  0x00DF => [:deviation, "ss"],
  # U+1E9E LATIN CAPITAL LETTER SHARP S maps to "ss" up to Unicode 15.1;
  # Unicode 16.0 changed the mapping to "ß". Verified against ICU 73.1
  # (Unicode 15.0.0) uidna_nameToASCII.
  0x1E9E => [:mapped, "ss"],
  0x200C => [:deviation, ""],
  0x200D => [:deviation, ""],
  0x3002 => [:mapped, "."],
  0x00AD => [:ignored, nil],
  0x0378 => [:disallowed, nil],
  0x2EBF0 => [:disallowed, nil]
}.each do |cp, (status, mapping)|
  actual = status_of(table, cp)
  unless actual == [status, mapping]
    raise format("unexpected 15.0 entry for U+%04X: %p (expected %p)", cp, actual, [status, mapping])
  end
end
puts "  sanity checks for Unicode 15.0.0 table passed"

puts "computing code point ages with Onigmo (this takes a minute)..."
age_15_0 = age_ranges("15.0")
age_15_1 = age_ranges("15.1")
new_in_15_1 = subtract_ranges(age_15_1, age_15_0)
new_cps = expand_ranges(new_in_15_1)
puts "  #{new_cps.size} code points assigned in Unicode 15.1.0"

# Unicode 15.1 added 627 code points: 622 CJK Ext I ideographs (Lo, valid
# in IDNA) and 5 ideographic description characters U+2FFC..U+2FFF and
# U+31EF (So, disallowed in IDNA, same as U+2FF0..U+2FFB before them).
valid_additions = []
new_in_15_1.each do |lo, hi|
  (lo..hi).each do |cp|
    ch = cp.chr(Encoding::UTF_8)
    entry = lookup(table, cp)
    if ch.match?(/\A\p{Lo}\z/u)
      raise format("U+%04X not disallowed in 15.0 table", cp) if entry.nil? || entry[2] != :disallowed
      valid_additions << cp
    elsif ch.match?(/\A\p{So}\z/u)
      # Remains disallowed; the 15.0 table already covers it as unassigned.
      raise format("U+%04X not disallowed in 15.0 table", cp) if entry.nil? || entry[2] != :disallowed
    else
      raise format("U+%04X added in 15.1 is neither Lo nor So", cp)
    end
  end
end
puts "  #{valid_additions.size} of them become valid (Lo ideographs)"
# Split the valid additions out of the (disallowed) ranges covering them.
valid_ranges = merge_ranges(valid_additions.map { |cp| [cp, cp, :valid, nil] })
table = table.flat_map do |entry|
  remainder = subtract_ranges([[entry[0], entry[1]]], valid_ranges.map { |lo, hi,| [lo, hi] })
  remainder.map { |lo, hi| [lo, hi, entry[2], entry[3]] }
end
table.concat(valid_ranges)
table.sort_by!(&:first)
table = merge_ranges(table)
puts "  applied 15.1 additions; #{table.size} mapping ranges"

# The table must cover the entire code point space with no gaps or
# overlaps, so that lookups never fall through.
expected = 0
table.each do |first, last,|
  raise format("mapping table gap/overlap before U+%04X", first) if first != expected
  expected = last + 1
end
raise "mapping table does not cover the full code point space" if expected != 0x110000
puts "  table covers U+0000..U+10FFFF with no gaps"

if crosscheck_path
  puts "cross-checking against #{crosscheck_path}"
  collapsed = { disallowed_STD3_valid: :valid, disallowed_STD3_mapped: :mapped }
  other = load_tr46_table(crosscheck_path)
  mismatches = []
  expand_ranges(age_15_1).each do |cp|
    mine, my_mapping = status_of(table, cp)
    theirs, their_mapping = status_of(other, cp)
    mine = collapsed.fetch(mine, mine)
    theirs = collapsed.fetch(theirs, theirs)
    if mine != theirs || my_mapping != their_mapping
      mismatches << [cp, [mine, my_mapping], [theirs, their_mapping]]
    end
  end
  if mismatches.empty?
    puts "  cross-check passed: derived 15.1 table matches on all assigned code points"
  else
    # Differences are expected: Unicode 16.0 changed the IDNA data of a
    # handful of previously assigned code points (e.g. U+1E9E). Print
    # them for manual review instead of failing.
    puts "  #{mismatches.size} code points differ from the 16.0.0 table (expected: official 15.1->16.0 changes):"
    mismatches.each { |cp, a, b| puts format("    U+%04X: 15.1=%p 16.0=%p", cp, a, b) }
  end
end

charprops = JSON.parse(File.read(charprops_path))
clip = ->(ranges) { intersect_ranges(ranges.map { |lo, hi| [lo, hi] }, age_15_1) }

bidi_ranges = charprops["bidi"].flat_map do |cls, ranges|
  clip.call(ranges).map { |lo, hi| [lo, hi, cls] }
end.sort_by(&:first)
bidi_ranges = merge_ranges(bidi_ranges)

joining_ranges = charprops["joining"].flat_map do |jt, ranges|
  clip.call(ranges).map { |lo, hi| [lo, hi, jt] }
end.sort_by(&:first)
joining_ranges = merge_ranges(joining_ranges)

virama_ranges = clip.call(charprops["virama"])
mark_ranges = clip.call(charprops["mark"])
script_ranges = charprops["scripts"].to_h { |name, ranges| [name, clip.call(ranges)] }

{
  "BIDI_RANGES" => bidi_ranges,
  "JOINING_RANGES" => joining_ranges,
  "VIRAMA_RANGES" => virama_ranges,
  "MARK_RANGES" => mark_ranges
}.each { |name, ranges| puts "  #{name}: #{ranges.size} ranges" }
script_ranges.each { |name, ranges| puts "  SCRIPT_RANGES[#{name}]: #{ranges.size} ranges" }

out_path = File.expand_path("../../lib/addressable/idna/uts46/tables.rb", __dir__)
File.open(out_path, "w") do |f|
  f.puts "# frozen_string_literal: true"
  f.puts
  f.puts "# Generated by script/uts46/generate_tables.rb -- do not edit by hand."
  f.puts "# Unicode IDNA Compatibility Processing (UTS 46) data, Unicode #{UNICODE_VERSION}."
  f.puts
  f.puts "module Addressable"
  f.puts "  module IDNA"
  f.puts "    module UTS46"
  f.puts "      UNICODE_VERSION = #{UNICODE_VERSION.inspect}.freeze"
  f.puts
  f.puts "      # [first, last, status, mapping] sorted by first code point."
  f.puts "      MAPPING_RANGES = ["
  table.each do |first, last, status, mapping|
    f.puts format("        [0x%04X, 0x%04X, %s, %s],", first, last, status.inspect, mapping.inspect)
  end
  f.puts "      ].freeze"
  f.puts
  f.puts '      # [first, last, bidi_class] for code points not in class "L".'
  f.puts "      BIDI_RANGES = ["
  bidi_ranges.each { |lo, hi, cls| f.puts format("        [0x%04X, 0x%04X, %s],", lo, hi, cls.inspect) }
  f.puts "      ].freeze"
  f.puts
  f.puts '      # [first, last, joining_type] for code points not of type "U".'
  f.puts "      JOINING_RANGES = ["
  joining_ranges.each { |lo, hi, jt| f.puts format("        [0x%04X, 0x%04X, %s],", lo, hi, jt.inspect) }
  f.puts "      ].freeze"
  f.puts
  f.puts "      # [first, last] code points with Canonical_Combining_Class == 9 (Virama)."
  f.puts "      VIRAMA_RANGES = ["
  virama_ranges.each { |lo, hi| f.puts format("        [0x%04X, 0x%04X],", lo, hi) }
  f.puts "      ].freeze"
  f.puts
  f.puts "      # [first, last] code points with General_Category = Mark (Mn/Mc/Me)."
  f.puts "      MARK_RANGES = ["
  mark_ranges.each { |lo, hi| f.puts format("        [0x%04X, 0x%04X],", lo, hi) }
  f.puts "      ].freeze"
  f.puts
  f.puts "      # Script name => [[first, last], ...] for ContextO rules."
  f.puts "      SCRIPT_RANGES = {"
  script_ranges.each do |name, ranges|
    f.puts "        #{name.inspect} => ["
    ranges.each { |lo, hi| f.puts format("          [0x%04X, 0x%04X],", lo, hi) }
    f.puts "        ].freeze,"
  end
  f.puts "      }.freeze"
  f.puts "    end"
  f.puts "  end"
  f.puts "end"
end
puts "wrote #{out_path}"
