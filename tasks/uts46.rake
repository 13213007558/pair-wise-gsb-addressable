# frozen_string_literal: true

namespace :uts46 do
  desc "Regenerate lib/addressable/idna/uts46_data.rb from Unicode data files"
  task :data do
    dir = ENV["UCD_DIR"] || ".gsb/tmp/ucd"
    output = "lib/addressable/idna/uts46_data.rb"
    inputs = {
      "IdnaMappingTable.txt" => "https://www.unicode.org/Public/idna/15.1.0/IdnaMappingTable.txt",
      "DerivedBidiClass.txt" => "https://www.unicode.org/Public/15.1.0/ucd/DerivedBidiClass.txt",
      "ppucd.txt" => "icu4c/source/data/unidata/ppucd.txt (ICU 74.2)",
      "UnicodeData.txt" => "https://www.unicode.org/Public/15.1.0/ucd/UnicodeData.txt",
      "DerivedNormalizationProps.txt" => "https://www.unicode.org/Public/15.1.0/ucd/DerivedNormalizationProps.txt"
    }
    missing = inputs.keys.reject { |name| File.exist?(File.join(dir, name)) }
    unless missing.empty?
      abort "Missing input files in #{dir}:\n" +
        missing.map { |name| "  #{name} (#{inputs[name]})" }.join("\n")
    end
    ruby "tasks/uts46/generate_uts46_data.rb " +
      %w[IdnaMappingTable.txt DerivedBidiClass.txt ppucd.txt UnicodeData.txt DerivedNormalizationProps.txt]
        .map { |name| File.join(dir, name) }.join(" ") + " #{output}"
  end
end
