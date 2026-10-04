# frozen_string_literal: true

# Generates lib/addressable/idna/uts46_data.rb from Unicode data files.
#
# The generated tables are pinned to a single Unicode version (currently
# 15.1.0) so that production code never has to download rule tables.
#
# Usage:
#   ruby tasks/uts46/generate_uts46_data.rb \
#     IdnaMappingTable.txt DerivedBidiClass.txt ppucd.txt \
#     lib/addressable/idna/uts46_data.rb
#
# Input files:
# * IdnaMappingTable.txt - UTS #46 mapping table, e.g.
#   https://www.unicode.org/Public/idna/15.1.0/IdnaMappingTable.txt
#   Columns used: codepoint(s); status; optional mapping.
# * DerivedBidiClass.txt - Bidi_Class values, e.g.
#   https://www.unicode.org/Public/15.1.0/ucd/DerivedBidiClass.txt
#   Only rows for classes other than Left_To_Right are needed; the
#   Left_To_Right default is implied.
# * ppucd.txt - ICU's preparsed UCD (icu4c/source/data/unidata/ppucd.txt
#   from ICU 74.2, which is Unicode 15.1.0). Used only for Joining_Type
#   (jt) and Script (sc); DerivedJoiningType.txt and Scripts.txt from
#   the same Unicode version carry the same information.
# * UnicodeData.txt - https://www.unicode.org/Public/15.1.0/ucd/UnicodeData.txt
#   Used for General_Category (marks), Canonical_Combining_Class and
#   canonical Decomposition_Mapping (entries without a <tag>).
# * DerivedNormalizationProps.txt - used for Full_Composition_Exclusion,
#   https://www.unicode.org/Public/15.1.0/ucd/DerivedNormalizationProps.txt

UNICODE_VERSION = "15.1.0"

STATUS_IDS = {
  "valid" => 0,
  "ignored" => 1,
  "mapped" => 2,
  "deviation" => 3,
  "disallowed" => 4,
  "disallowed_STD3_valid" => 5,
  "disallowed_STD3_mapped" => 6
}.freeze

BIDI_IDS = {
  "L" => 0, "R" => 1, "AL" => 2, "EN" => 3, "ES" => 4, "ET" => 5,
  "AN" => 6, "CS" => 7, "BN" => 8, "B" => 9, "S" => 10, "WS" => 11,
  "ON" => 12, "NSM" => 13, "LRE" => 14, "LRO" => 15, "RLE" => 16,
  "RLO" => 17, "LRI" => 18, "RLI" => 19, "FSI" => 20, "PDI" => 21,
  "PDF" => 22
}.freeze

BIDI_LONG_NAMES = {
  "Right_To_Left" => "R", "Arabic_Letter" => "AL",
  "European_Number" => "EN", "European_Separator" => "ES",
  "European_Terminator" => "ET", "Arabic_Number" => "AN",
  "Common_Separator" => "CS", "Boundary_Neutral" => "BN",
  "Segment_Separator" => "S", "White_Space" => "WS",
  "Other_Neutral" => "ON", "Nonspacing_Mark" => "NSM"
}.freeze

JOINING_IDS = { "R" => 1, "D" => 2, "L" => 3, "T" => 4 }.freeze

SCRIPT_IDS = {
  "Grek" => 0, "Hebr" => 1, "Hani" => 2, "Hira" => 3, "Kana" => 4
}.freeze

def parse_range(field)
  if field.include?("..")
    first, last = field.split("..", 2)
    [Integer(first, 16), Integer(last, 16)]
  else
    cp = Integer(field, 16)
    [cp, cp]
  end
end

def parse_mapping_table(path)
  rows = []
  File.foreach(path) do |line|
    line = line.sub(/#.*$/, "").strip
    next if line.empty?
    parts = line.split(";", 3)
    range_s = parts[0].strip
    status = parts[1].strip
    # A present-but-empty third column means "maps to the empty
    # string" (e.g. U+200C/U+200D are deviations mapping to nothing);
    # a missing column means the status has no mapping at all.
    mapping_s = parts.length > 2 ? parts[2].strip : nil
    first, last = parse_range(range_s)
    status_id = STATUS_IDS.fetch(status) do
      raise "Unknown status #{status.inspect} in #{path}"
    end
    mapping = nil
    if mapping_s
      mapping = mapping_s.split(/\s+/).map { |cp| Integer(cp, 16) }.pack("U*")
    end
    rows << [first, last, status_id, mapping]
  end
  rows.sort_by!(&:first)
  merged = []
  rows.each do |row|
    if merged.any? && merged[-1][3].nil? && row[3].nil? &&
       merged[-1][2] == row[2] && merged[-1][1] + 1 == row[0]
      merged[-1][1] = row[1]
    else
      merged << row.dup
    end
  end
  merged
end

def parse_bidi_class(path)
  rows = []
  File.foreach(path) do |line|
    line = line.sub(/#.*$/, "").strip
    next if line.empty?
    range_s, klass = line.split(";", 2).map { |part| part.strip }
    klass = BIDI_LONG_NAMES.fetch(klass, klass)
    next if klass == "L"
    id = BIDI_IDS.fetch(klass) { raise "Unknown bidi class #{klass.inspect}" }
    first, last = parse_range(range_s)
    rows << [first, last, id]
  end
  rows.sort_by!(&:first)
  merged = []
  rows.each do |row|
    if merged.any? && merged[-1][2] == row[2] && merged[-1][1] + 1 >= row[0]
      merged[-1][1] = row[1] if row[1] > merged[-1][1]
    else
      merged << row.dup
    end
  end
  merged
end

def parse_ppucd(path)
  cp_props = {}
  block_defaults = []
  File.foreach(path) do |line|
    next unless line.start_with?("cp;") || line.start_with?("block;")
    kind, range_s, *rest = line.strip.split(";")
    cp_first, cp_last = parse_range(range_s)
    props = {}
    rest.each do |field|
      if field.include?("=")
        key, value = field.split("=", 2)
        props[key] = value
      else
        props[field] = true
      end
    end
    # Distinguish "property not mentioned" (nil: fall back to the block
    # default) from an explicit default value (:none: no table entry).
    jt = props.key?("jt") ? (JOINING_IDS[props["jt"]] || :none) : nil
    sc = props.key?("sc") ? (SCRIPT_IDS[props["sc"]] || :none) : nil
    if kind == "block"
      block_defaults << [cp_first, cp_last, jt == :none ? nil : jt, sc == :none ? nil : sc]
    else
      (cp_first..cp_last).each do |cp|
        cp_props[cp] = [jt, sc] if jt || sc
      end
    end
  end
  { cp_props: cp_props, block_defaults: block_defaults }
end

def parse_unicode_data(path)
  marks = []
  ccc_rows = []
  decompose = {}
  assigned = {}
  first_of_range = nil
  File.foreach(path) do |line|
    fields = line.strip.split(";")
    cp = Integer(fields[0], 16)
    name = fields[1]
    if name.end_with?(", First>")
      first_of_range = cp
      next
    elsif name.end_with?(", Last>")
      (first_of_range..cp).each { |c| assigned[c] = true }
      first_of_range = nil
      next
    end
    assigned[cp] = true
    marks << cp if %w[Mn Mc Me].include?(fields[2])
    ccc = fields[3].to_i
    ccc_rows << [cp, ccc] if ccc != 0
    dm = fields[5]
    next if dm.nil? || dm.empty? || dm.include?("<")
    decompose[cp] = dm.split(/\s+/).map { |part| Integer(part, 16) }
  end
  {
    marks: to_ranges(marks.map { |cp| [cp, 0] }),
    ccc: to_ranges(ccc_rows),
    decompose: decompose,
    assigned: assigned
  }
end

def parse_composition_exclusions(path)
  exclusions = {}
  File.foreach(path) do |line|
    line = line.sub(/#.*$/, "").strip
    next if line.empty?
    range_s, prop = line.split(";", 2).map { |part| part.strip }
    next unless prop == "Full_Composition_Exclusion"
    first, last = parse_range(range_s)
    (first..last).each { |cp| exclusions[cp] = true }
  end
  exclusions
end

def to_ranges(pairs)
  pairs.sort_by!(&:first)
  ranges = []
  pairs.each do |cp, value|
    if ranges.any? && ranges[-1][2] == value && ranges[-1][1] + 1 == cp
      ranges[-1][1] = cp
    else
      ranges << [cp, cp, value]
    end
  end
  ranges
end

def emit_string(str)
  '"' + str.codepoints.map { |cp|
    if cp >= 0x20 && cp < 0x7F && cp != 0x22 && cp != 0x5C
      cp.chr
    else
      "\\u{#{cp.to_s(16).upcase}}"
    end
  }.join + '"'
end

def emit_table(io, name, rows)
  io.puts "      #{name} = ["
  rows.each do |row|
    io.puts "        [#{row.join(', ')}],"
  end
  io.puts "      ].freeze"
  io.puts
end

def main
  mapping_path, bidi_path, ppucd_path, unicode_data_path, norm_props_path, output_path = *ARGV
  unless mapping_path && bidi_path && ppucd_path && unicode_data_path && norm_props_path && output_path
    warn "Usage: ruby #{__FILE__} IdnaMappingTable.txt DerivedBidiClass.txt ppucd.txt UnicodeData.txt DerivedNormalizationProps.txt OUTPUT"
    exit 1
  end

  mapping = parse_mapping_table(mapping_path)
  bidi = parse_bidi_class(bidi_path)
  ppucd = parse_ppucd(ppucd_path)
  norm = parse_unicode_data(unicode_data_path)
  compose_exclusions = parse_composition_exclusions(norm_props_path)
  compose = {}
  norm[:decompose].each do |cp, parts|
    next unless parts.length == 2
    next if compose_exclusions[cp]
    compose[(parts[0] << 21) | parts[1]] = cp
  end

  # Joining_Type and Script come from ppucd's three-tier data: explicit
  # code point values win, assigned code points fall back to their
  # block's default, and unassigned code points use the UCD @missing
  # defaults (Joining_Type=U, Script=Zzzz, i.e. no table entry).
  jt_block = []
  sc_block = []
  ppucd[:block_defaults].each do |first, last, jt, sc|
    jt_block << [first, last, jt] if jt
    sc_block << [first, last, sc] if sc
  end
  joining = []
  scripts = []
  jt_block.sort_by!(&:first)
  sc_block.sort_by!(&:first)
  0x110000.times do |cp|
    explicit = ppucd[:cp_props][cp]
    jt = explicit && explicit[0]
    sc = explicit && explicit[1]
    if norm[:assigned][cp]
      unless jt
        row = jt_block.bsearch { |r| cp <= r[1] ? (cp >= r[0] ? 0 : -1) : 1 }
        jt = row[2] if row
      end
      unless sc
        row = sc_block.bsearch { |r| cp <= r[1] ? (cp >= r[0] ? 0 : -1) : 1 }
        sc = row[2] if row
      end
    end
    # An explicit UCD default value (Joining_Type=U, Script=Zzzz) means
    # "no table entry" and must not fall back to the block default.
    jt = nil if jt == :none
    sc = nil if sc == :none
    joining << [cp, jt] if jt
    scripts << [cp, sc] if sc
  end
  joining = to_ranges(joining)
  scripts = to_ranges(scripts)

  # Sanity check: the only code points mapping to "." must be the three
  # well-known dot variants; the runtime label splitter relies on this.
  dot_mappers = mapping.select { |row| row[3] == "." }.map { |row| row[0] }
  unless dot_mappers == [0x3002, 0xFF0E, 0xFF61]
    raise "Unexpected code points mapping to '.': #{dot_mappers.inspect}"
  end

  File.open(output_path, "w") do |io|
    io.puts "# frozen_string_literal: true"
    io.puts
    io.puts "# Generated by tasks/uts46/generate_uts46_data.rb from Unicode"
    io.puts "# #{UNICODE_VERSION} data files. Do not edit by hand."
    io.puts "#"
    io.puts "# These tables are the only Unicode data the UTS #46 implementation"
    io.puts "# needs at runtime; nothing is downloaded in production."
    io.puts
    io.puts "module Addressable"
    io.puts "  module IDNA"
    io.puts "    module UTS46"
    io.puts "      UNICODE_VERSION = #{UNICODE_VERSION.dump}.freeze"
    io.puts
    io.puts "      STATUS_VALID = 0"
    io.puts "      STATUS_IGNORED = 1"
    io.puts "      STATUS_MAPPED = 2"
    io.puts "      STATUS_DEVIATION = 3"
    io.puts "      STATUS_DISALLOWED = 4"
    io.puts "      STATUS_DISALLOWED_STD3_VALID = 5"
    io.puts "      STATUS_DISALLOWED_STD3_MAPPED = 6"
    io.puts
    emit_table(io, "MAPPING", mapping.map { |row| [row[0], row[1], row[2], row[3] ? emit_string(row[3]) : "nil"] })
    BIDI_IDS.each do |name, id|
      io.puts "      BIDI_#{name} = #{id}"
    end
    io.puts
    emit_table(io, "BIDI", bidi)
    io.puts "      JT_OTHER = 0"
    io.puts "      JT_RIGHT = 1"
    io.puts "      JT_DUAL = 2"
    io.puts "      JT_LEFT = 3"
    io.puts "      JT_TRANSPARENT = 4"
    io.puts
    emit_table(io, "JOINING", joining)
    io.puts "      SCRIPT_GREEK = 0"
    io.puts "      SCRIPT_HEBREW = 1"
    io.puts "      SCRIPT_HAN = 2"
    io.puts "      SCRIPT_HIRAGANA = 3"
    io.puts "      SCRIPT_KATAKANA = 4"
    io.puts
    emit_table(io, "SCRIPTS", scripts)
    emit_table(io, "MARKS", norm[:marks])
    emit_table(io, "CCC", norm[:ccc])
    io.puts "      DECOMPOSE = {"
    norm[:decompose].sort.each do |cp, parts|
      io.puts "        #{cp} => [#{parts.join(', ')}],"
    end
    io.puts "      }.freeze"
    io.puts
    io.puts "      COMPOSE = {"
    compose.sort.each do |key, cp|
      io.puts "        #{key} => #{cp},"
    end
    io.puts "      }.freeze"
    io.puts "    end"
    io.puts "  end"
    io.puts "end"
  end

  warn "Wrote #{output_path}: " \
    "#{mapping.size} mapping rows, #{bidi.size} bidi ranges, " \
    "#{joining.size} joining ranges, #{scripts.size} script ranges, " \
    "#{norm[:marks].size} mark ranges, #{norm[:ccc].size} ccc ranges, " \
    "#{norm[:decompose].size} decompositions, #{compose.size} compositions"
end

main if __FILE__ == $PROGRAM_NAME
