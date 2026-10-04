# frozen_string_literal: true

# Development-only generator for lib/addressable/idna/data/uts46-15.1.0.json.
# Inputs are local copies of Unicode 15.1.0 UCD files; production code only
# reads the generated JSON file.

require "json"
require "fileutils"

UNICODE_VERSION = "15.1.0"
UNICODE_SOURCE = ENV.fetch(
  "ICU_UNICODE_SOURCE",
  "/tmp/icu/icu4c/source/data/unidata"
)
NODE_UNICODE_SOURCE = ENV.fetch(
  "NODE_UNICODE_SOURCE",
  "/tmp/unicode151"
)
IDNA_DATA_FILE = File.expand_path(
  "../../lib/addressable/idna/data/uts46-#{UNICODE_VERSION}.json",
  __FILE__
)

def hex_codepoint(value)
  value.to_i(16)
end

def parse_uts46_mappings(path)
  entries = {}
  File.readlines(path, chomp: true).each do |source_line|
    commented = source_line.start_with?("#")
    source_line = source_line.sub(/\A#\s*/, "").split("#", 2).first
    next if source_line.nil? || source_line.strip.empty?
    statuses = %w[valid ignored mapped disallowed_STD3_valid disallowed_STD3_mapped disallowed deviation].join("|")
    match = source_line.match(/\A#?\s*([0-9A-F]+)(?:\.\.([0-9A-F]+))?(?:\s+(#{statuses}))?(?:\s*>([0-9A-F ]*))?/)
    next unless match

    start = hex_codepoint(match[1])
    finish = match[2] ? hex_codepoint(match[2]) : start
    status = match[3]
    mapping = (match[4] || "").strip.split.map { |codepoint| hex_codepoint(codepoint) }

    unless match[3]
      if commented
        status = "valid"
      elsif mapping == [0xFFFD]
        status = "disallowed"
      elsif mapping.empty?
        status = "ignored"
      else
        status = "mapped"
      end
    end

    (start..finish).each do |codepoint|
      entries[codepoint] = [status, mapping].freeze
    end
  end

  raise "Incomplete UTS #46 mapping table" unless entries.size == 0x110000

  grouped = []
  entries.each.sort.each do |codepoint, entry|
    if grouped.last && grouped.last[2] == entry
      grouped.last[1] = codepoint
    else
      grouped << [codepoint, codepoint, entry]
    end
  end
  grouped.map { |start, finish, entry| [start, finish == start ? nil : finish, entry[0], entry[1]] }
end

def parse_unicode_data(path)
  ccc = {}
  decomposition = {}
  composition = {}

  File.foreach(path, chomp: true) do |line|
    fields = line.split(";", -1)
    codepoint = hex_codepoint(fields[0])
    combining_class = fields[3].to_i
    ccc[codepoint] = combining_class unless combining_class.zero?

    raw_decomposition = fields[5]
    next if raw_decomposition.empty? || raw_decomposition.start_with?("<")

    mapped = raw_decomposition.split.map { |value| hex_codepoint(value) }
    decomposition[codepoint] = mapped
    composition[mapped] = codepoint if mapped.length == 2
  end

  [ccc, decomposition, composition]
end

def sparse_ranges(values)
  values.sort.each_with_object([]) do |value, ranges|
    if ranges.last
      if ranges.last.last + 1 == value
        ranges.last << value
      else
        ranges << [value]
      end
    else
      ranges << [value]
    end
  end.map { |range| range.length == 1 ? range.first : [range.first, range.last] }
end

def node_property(*parts)
  path = File.join(NODE_UNICODE_SOURCE, *parts, "code-points.mjs")
  output = IO.popen(
    ["node", "--input-type=module", "-e", "import('#{path}').then(m => process.stdout.write(JSON.stringify(m.default)))"],
    &:read
  )
  raise "Unable to read #{path}" unless $?.success?
  sparse_ranges(JSON.parse(output))
end

if __FILE__ == $PROGRAM_NAME
  ccc, decomposition, composition = parse_unicode_data(
    File.join(UNICODE_SOURCE, "UnicodeData.txt")
  )
  exclusions = JSON.parse(
    File.read(File.join(NODE_UNICODE_SOURCE, "Binary_Property/Full_Composition_Exclusion/code-points.mjs"))
  ) rescue nil
  if exclusions.nil?
    exclusions = node_property("Binary_Property", "Full_Composition_Exclusion")
  else
    exclusions = sparse_ranges(exclusions)
  end
  composition.reject! do |_mapped, codepoint|
    exclusions.any? do |range|
      range_start, range_end = range.is_a?(Array) ? range : [range, range]
      codepoint >= range_start && codepoint <= range_end
    end
  end

  data = {
    "unicode_version" => UNICODE_VERSION,
    "mappings" => parse_uts46_mappings(
      File.join(UNICODE_SOURCE, "norm2", "uts46.txt")
    ),
    "ccc" => ccc,
    "canonical_decomposition" => decomposition,
    "canonical_composition" => composition.transform_keys { |mapped| mapped.join("/") },
    "properties" => {
      "mark" => node_property("General_Category", "Mark"),
      "bidi" => %w[
        Left_To_Right Right_To_Left Arabic_Letter Arabic_Number
        European_Number European_Separator European_Terminator
        Common_Separator Nonspacing_Mark Boundary_Neutral Other_Neutral
      ].map { |name| [name, node_property("Bidi_Class", name)] }.to_h,
      "joining" => %w[Dual_Joining Right_Joining Left_Joining Transparent]
        .map { |name| [name, node_property("Joining_Type", name)] }.to_h,
      "scripts" => %w[Greek Hebrew Hiragana Katakana Han]
        .map { |name| [name, node_property("Script_Extensions", name)] }.to_h
    }
  }

  FileUtils.mkdir_p(File.dirname(IDNA_DATA_FILE))
  File.write(IDNA_DATA_FILE, JSON.generate(data))
  puts "Wrote #{IDNA_DATA_FILE} (#{File.size(IDNA_DATA_FILE)} bytes)"
end
