#!/usr/bin/env ruby
# frozen_string_literal: true

# Compares Addressable::IDNA::UTS46 against the expected results
# produced by script/uts46/fuzz.mjs (tr46 oracle) for random domains.
#
# Usage:
#   node script/uts46/fuzz.mjs 1 20000 > .tmp/uts46/fuzz.jsonl
#   ruby -Ilib script/uts46/fuzz.rb .tmp/uts46/fuzz.jsonl

require "json"
require "addressable/idna/uts46"

failures = []
total = 0

File.foreach(ARGV[0]) do |line|
  row = JSON.parse(line)
  domain = row["domain"]
  {
    "anr" => [false, false],
    "ans" => [false, true],
    "atr" => [true, false],
    "ats" => [true, true]
  }.each do |key, (transitional, std3)|
    expected = row[key]
    total += 1
    begin
      actual = Addressable::IDNA::UTS46.to_ascii(
        domain, transitional: transitional, use_std3_ascii_rules: std3
      )
      if expected == "ERROR"
        # Deliberate difference: UTS 46 VerifyDNSLength permits a
        # trailing root label ("example.com."), tr46 rejects it.
        failures << [domain, key, "expected ERROR, got #{actual.inspect}"] unless actual.end_with?(".")
      elsif actual != expected
        failures << [domain, key, "expected #{expected.inspect}, got #{actual.inspect}"]
      end
    rescue Addressable::IDNA::UTS46::Error => e
      failures << [domain, key, "expected #{expected.inspect}, got error #{e.rule}"] if expected != "ERROR"
    end
  end

  if row.key?("u")
    total += 1
    actual = Addressable::IDNA::UTS46.to_unicode(domain)
    failures << [domain, "u", "expected #{row['u'].inspect}, got #{actual.inspect}"] if actual != row["u"]
  end
end

failures.first(20).each { |d, k, msg| puts "#{k} #{d.inspect}: #{msg}" }
puts "#{total} comparisons, #{failures.size} mismatches"
exit(failures.empty? ? 0 : 1)
