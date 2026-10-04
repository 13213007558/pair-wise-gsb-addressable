# frozen_string_literal: true

require "spec_helper"
require "addressable/idna"

RSpec.describe Addressable::IDNA::UTS46 do
  def unescape_idna(value)
    value = value.gsub(/\\x\{([0-9A-Fa-f]+)\}/) do
      [$1.to_i(16)].pack("U")
    end
    value.gsub(/\\u([0-9A-Fa-f]{4})/) do
      [$1.to_i(16)].pack("U")
    end
  end

  def statuses(value)
    value.to_s.scan(/[A-Z]+[0-9]*(?:_[0-9]+)?/)
  end

  def expected_error?(statuses, operation)
    statuses.any? do |status|
      case status
      when "P4", "A1", "A2", "A3", "A4_1", "A4_2"
        operation == :ascii
      when "U1"
        true
      when "V2", "V3"
        true
      when "B1", "B2", "B3", "B4", "B5", "B6", "V8"
        true
      when "C1", "C2", "V7"
        true
      when "V1", "V5", "V6"
        true
      when /\AX/
        operation == :ascii
      else
        false
      end
    end
  end

  def official_cases
    @official_cases ||= File.readlines(
      File.expand_path("../../fixtures/IdnaTestV2-15.1.0.txt", __FILE__),
      chomp: true, encoding: "UTF-8"
    ).each_with_object([]) do |line, cases|
      next if line.start_with?("#")
      columns = line.split(";", 7).first(7).map(&:strip)
      next if columns.length < 7
      source = unescape_idna(columns[0])
      unicode_value = columns[1].empty? ? source : unescape_idna(columns[1])
      unicode_status = statuses(columns[2])
      ascii_n_value = columns[3].empty? ? unicode_value : unescape_idna(columns[3])
      ascii_n_status = columns[4].empty? ? unicode_status : statuses(columns[4])
      ascii_t_value = columns[5].empty? ? ascii_n_value : unescape_idna(columns[5])
      ascii_t_status = columns[6].split("#", 2).first.strip.empty? ? ascii_n_status : statuses(columns[6])
      cases << [source, unicode_value, unicode_status, ascii_n_value,
                ascii_n_status, ascii_t_value, ascii_t_status]
    end
  end

  let(:unicode_profile) do
    Addressable::IDNA::Profile.new(
      use_std3_ascii_rules: true,
      check_hyphens: true,
      check_bidi: true,
      check_joiners: true
    )
  end
  let(:nontransitional_profile) { Addressable::IDNA::STRICT_PROFILE }
  let(:transitional_profile) do
    Addressable::IDNA::Profile.new(
      transitional: true,
      use_std3_ascii_rules: true,
      check_hyphens: true,
      check_bidi: true,
      check_joiners: true,
      verify_dns_length: true
    )
  end

  it "matches Unicode 15.1.0 ToUnicode conformance vectors" do
    failures = official_cases.filter_map do |test_case|
      source, expected, status = test_case
      result = unicode_profile.to_unicode(source)
      error_expected = expected_error?(status, :unicode)
      next if (result.error != nil) == error_expected
      next if error_expected
      next if result.to_s == expected
      [source, expected, result.to_s, status]
    end
    expect(failures.first(20)).to eq([])
  end

  it "matches Unicode 15.1.0 nontransitional ToASCII conformance vectors" do
    failures = official_cases.filter_map do |test_case|
      source, _unicode, _ustatus, expected, status = test_case
      result = nontransitional_profile.to_ascii(source)
      error_expected = expected_error?(status, :ascii)
      next if (result.error != nil) == error_expected
      next if error_expected
      next if result.to_s == expected
      [source, expected, result.to_s, status]
    end
    expect(failures.first(20)).to eq([])
  end

  it "matches Unicode 15.1.0 transitional ToASCII conformance vectors" do
    failures = official_cases.filter_map do |test_case|
      source, _u, _us, _an, _ans, expected, status = test_case
      result = transitional_profile.to_ascii(source)
      error_expected = expected_error?(status, :ascii)
      next if (result.error != nil) == error_expected
      next if error_expected
      next if result.to_s == expected
      [source, expected, result.to_s, status]
    end
    expect(failures.first(20)).to eq([])
  end

  it "keeps transitional and nontransitional sharp-s behavior separate" do
    expect(nontransitional_profile.to_ascii!("faß.de")).to eq("xn--fa-hia.de")
    expect(transitional_profile.to_ascii!("faß.de")).to eq("fass.de")
  end

  it "reports failures by label without accepting decodable-but-invalid Punycode" do
    result = nontransitional_profile.to_ascii("good.xn--a-Ä.bad")
    expect(result.error).to be_a(Addressable::IDNA::IdnaError)
    expect(result.errors_by_label.keys).to contain_exactly(1)
    expect(result.to_s.split(".")[1]).to start_with("xn--")
  end

  it "applies check_hyphens only when enabled" do
    permissive = Addressable::IDNA::Profile.new(check_hyphens: false)
    strict = Addressable::IDNA::Profile.new(check_hyphens: true)
    expect(permissive.to_ascii("-example-")).to be_success
    expect(strict.to_ascii("-example-")).not_to be_success
  end

  it "applies STD3 ASCII restrictions only when enabled" do
    permissive = Addressable::IDNA::Profile.new(use_std3_ascii_rules: false)
    strict = Addressable::IDNA::Profile.new(use_std3_ascii_rules: true)
    expect(permissive.to_ascii("ex_ample.com")).to be_success
    expect(strict.to_ascii("ex_ample.com")).not_to be_success
  end

  it "applies ContextJ only when enabled" do
    permissive = Addressable::IDNA::Profile.new(check_joiners: false)
    strict = Addressable::IDNA::Profile.new(check_joiners: true)
    expect(permissive.to_ascii("a\u200Cb")).to be_success
    expect(strict.to_ascii("a\u200Cb")).not_to be_success
    expect(strict.to_ascii("a\u094D\u200Cb")).to be_success
  end

  it "applies ContextO independently" do
    disabled = Addressable::IDNA::Profile.new(check_context_o: false)
    enabled = Addressable::IDNA::Profile.new(check_context_o: true)
    expect(disabled.to_ascii("l\u00B7l")).to be_success
    expect(enabled.to_ascii("l\u00B7l")).to be_success
    expect(enabled.to_ascii("a\u00B7b")).not_to be_success
    expect(enabled.to_ascii("\u0660\u06F0")).not_to be_success
  end

  it "applies Bidi only when enabled" do
    disabled = Addressable::IDNA::Profile.new(check_bidi: false)
    enabled = Addressable::IDNA::Profile.new(check_bidi: true)
    expect(disabled.to_ascii("à\u05D0")).to be_success
    expect(enabled.to_ascii("à\u05D0")).not_to be_success
  end

  it "rejects RTL isolates and reports the offending label" do
    profile = Addressable::IDNA::Profile.new(check_bidi: true)
    result = profile.to_ascii("\u2066\u05D0")
    expect(result.errors_by_label).to eq(0 => [:disallowed])
  end

  it "applies DNS length limits only when requested" do
    label = "a" * 64
    disabled = Addressable::IDNA::Profile.new(verify_dns_length: false)
    enabled = Addressable::IDNA::Profile.new(verify_dns_length: true)
    expect(disabled.to_ascii(label)).to be_success
    expect(enabled.to_ascii(label)).not_to be_success
  end

  it "keeps independently created profiles from affecting each other" do
    one = Addressable::IDNA::Profile.new(check_bidi: true)
    two = Addressable::IDNA::Profile.new(check_joiners: true)
    expect(one.check_bidi).to eq(true)
    expect(one.check_joiners).to eq(false)
    expect(two.check_bidi).to eq(false)
    expect(two.check_joiners).to eq(true)
  end

  it "keeps strict registration and display configurations separate" do
    registration = Addressable::IDNA::STRICT_PROFILE
    display = Addressable::IDNA::DISPLAY_PROFILE

    expect(registration.verify_dns_length).to eq(true)
    expect(display.verify_dns_length).to eq(false)
    expect(display.check_context_o).to eq(true)
    expect(registration.check_context_o).to eq(true)
  end

  it "exposes the bundled Unicode version" do
    expect(Addressable::IDNA::UNICODE_VERSION).to eq("15.1.0")
  end
end
