# frozen_string_literal: true

# Copyright (C) Bob Aman
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

require "spec_helper"

require "addressable/idna/uts46"
require "addressable/uri"

UTS46 = Addressable::IDNA::UTS46 unless defined?(UTS46)

describe UTS46 do
  STD3_N = UTS46::Config.new(use_std3_ascii_rules: true)
  STD3_T = UTS46::Config.new(transitional: true, use_std3_ascii_rules: true)

  def self.unescape(str)
    str.gsub(/\\u([0-9A-Fa-f]{4})|\\x\{([0-9A-Fa-f]+)\}/) do
      [($1 || $2).to_i(16)].pack("U")
    end
  end

  def self.parse_status(str)
    str = str.strip
    return [] if str.empty? || str == "[]"
    str.gsub(/[\[\]]/, "").split(/[ ,]+/).reject(&:empty?).sort
  end

  # The official UTS #46 conformance test file, pinned to the same
  # Unicode version as the vendored data tables. Used offline.
  IDNA_TEST_V2 = File.join(
    File.dirname(__FILE__), "..", "data", "IdnaTestV2.txt"
  )

  # ContextO status codes (C3..C8) are optional and deliberately not
  # exercised by IdnaTestV2, so they are filtered out before comparing.
  CONTEXTO_CODES = %w[C3 C4 C5 C6 C7 C8].freeze

  def self.idna_test_vectors
    @idna_test_vectors ||= [].tap do |vectors|
      File.foreach(IDNA_TEST_V2, encoding: Encoding::UTF_8) do |line|
        line = line.sub(/#.*$/, "")
        next if line.strip.empty?
        cols = line.split(";", -1).map(&:strip)
        next if cols.length < 7
        source = unescape(cols[0])
        to_unicode = cols[1].empty? ? source : unescape(cols[1])
        to_unicode_status = parse_status(cols[2])
        to_ascii_n = cols[3].empty? ? to_unicode : unescape(cols[3])
        to_ascii_n_status = cols[4].empty? ? to_unicode_status : parse_status(cols[4])
        to_ascii_t = cols[5].empty? ? to_ascii_n : unescape(cols[5])
        to_ascii_t_status = cols[6].empty? ? to_ascii_n_status : parse_status(cols[6])
        vectors << {
          source: source,
          to_unicode: to_unicode, to_unicode_status: to_unicode_status,
          to_ascii_n: to_ascii_n, to_ascii_n_status: to_ascii_n_status,
          to_ascii_t: to_ascii_t, to_ascii_t_status: to_ascii_t_status
        }
      end
    end
  end

  def self.utf8(str)
    str.dup.force_encoding(Encoding::UTF_8)
  end

  describe "official IdnaTestV2.txt conformance (Unicode #{UTS46::UNICODE_VERSION})" do
    it "pins the test vectors to the vendored Unicode version" do
      header = File.readlines(IDNA_TEST_V2, encoding: Encoding::UTF_8).first(12).join
      expect(header).to include("Version: #{UTS46::UNICODE_VERSION}")
    end

    it "passes every toUnicode test vector" do
      failures = []
      self.class.idna_test_vectors.each do |vector|
        result = UTS46.to_unicode(vector[:source], config: STD3_N)
        codes = (result.errors.flat_map(&:codes) - CONTEXTO_CODES).uniq.sort
        problems = []
        if result.output != vector[:to_unicode]
          problems << "output #{result.output.inspect} != #{vector[:to_unicode].inspect}"
        end
        if codes != vector[:to_unicode_status]
          problems << "status [#{codes.join(' ')}] != [#{vector[:to_unicode_status].join(' ')}]"
        end
        failures << "#{vector[:source].inspect}: #{problems.join(', ')}" unless problems.empty?
      end
      expect(failures).to be_empty, -> {
        "#{failures.size} toUnicode failures, e.g.:\n" + failures.first(10).join("\n")
      }
    end

    it "passes every toASCII (nontransitional) test vector" do
      failures = []
      self.class.idna_test_vectors.each do |vector|
        result = UTS46.to_ascii(vector[:source], config: STD3_N)
        codes = (result.errors.flat_map(&:codes) - CONTEXTO_CODES).uniq.sort
        problems = []
        if result.output != vector[:to_ascii_n]
          problems << "output #{result.output.inspect} != #{vector[:to_ascii_n].inspect}"
        end
        if codes != vector[:to_ascii_n_status]
          problems << "status [#{codes.join(' ')}] != [#{vector[:to_ascii_n_status].join(' ')}]"
        end
        failures << "#{vector[:source].inspect}: #{problems.join(', ')}" unless problems.empty?
      end
      expect(failures).to be_empty, -> {
        "#{failures.size} toAsciiN failures, e.g.:\n" + failures.first(10).join("\n")
      }
    end

    it "passes every toASCII (transitional) test vector" do
      failures = []
      self.class.idna_test_vectors.each do |vector|
        result = UTS46.to_ascii(vector[:source], config: STD3_T)
        codes = (result.errors.flat_map(&:codes) - CONTEXTO_CODES).uniq.sort
        problems = []
        if result.output != vector[:to_ascii_t]
          problems << "output #{result.output.inspect} != #{vector[:to_ascii_t].inspect}"
        end
        if codes != vector[:to_ascii_t_status]
          problems << "status [#{codes.join(' ')}] != [#{vector[:to_ascii_t_status].join(' ')}]"
        end
        failures << "#{vector[:source].inspect}: #{problems.join(', ')}" unless problems.empty?
      end
      expect(failures).to be_empty, -> {
        "#{failures.size} toAsciiT failures, e.g.:\n" + failures.first(10).join("\n")
      }
    end
  end

  describe "Unicode data version" do
    it "is pinned to a specific Unicode version" do
      expect(UTS46::UNICODE_VERSION).to eq("15.1.0")
      expect(UTS46::UNICODE_VERSION).to be_frozen
    end
  end

  describe "predefined configurations" do
    it "provides a transitional and a nontransitional configuration" do
      expect(UTS46::TRANSITIONAL.transitional?).to be(true)
      expect(UTS46::NONTRANSITIONAL.transitional?).to be(false)
    end

    it "provides two independent, immutable configuration objects" do
      expect(UTS46::TRANSITIONAL).not_to equal(UTS46::NONTRANSITIONAL)
      expect(UTS46::TRANSITIONAL).to be_frozen
      expect(UTS46::NONTRANSITIONAL).to be_frozen
      expect { UTS46::TRANSITIONAL.instance_variable_set(:@transitional, false) }.to(
        raise_error(FrozenError)
      )
      expect(UTS46::NONTRANSITIONAL.transitional?).to be(false)
    end

    it "does not let one configuration affect the other's results" do
      domain = "fa\u00DF.de"
      transitional_result = UTS46.to_ascii(domain, config: UTS46::TRANSITIONAL)
      nontransitional_result = UTS46.to_ascii(domain, config: UTS46::NONTRANSITIONAL)
      expect(transitional_result.output).to eq("fass.de")
      expect(nontransitional_result.output).to eq("xn--fa-hia.de")
      # Running the transitional configuration again must not have been
      # affected by the nontransitional run, and vice versa.
      expect(UTS46.to_ascii(domain, config: UTS46::TRANSITIONAL).output).to eq("fass.de")
      expect(UTS46.to_ascii(domain, config: UTS46::NONTRANSITIONAL).output).to(
        eq("xn--fa-hia.de")
      )
    end

    it "treats configurations as value objects" do
      expect(UTS46::Config.new(transitional: true)).to eq(UTS46::TRANSITIONAL)
      expect(UTS46::Config.new).to eq(UTS46::NONTRANSITIONAL)
      expect(UTS46::Config.new(transitional: true)).not_to eq(UTS46::NONTRANSITIONAL)
    end
  end

  describe "options" do
    it "maps deviation characters only in transitional processing" do
      expect(UTS46.to_ascii("fa\u00DF.de").output).to eq("xn--fa-hia.de")
      expect(
        UTS46.to_ascii("fa\u00DF.de", config: UTS46::TRANSITIONAL).output
      ).to eq("fass.de")
    end

    it "rejects non-LDH ASCII only with UseSTD3ASCIIRules" do
      expect(UTS46.to_ascii("exa_mple.com").success?).to be(true)
      std3 = UTS46::Config.new(use_std3_ascii_rules: true)
      result = UTS46.to_ascii("exa_mple.com", config: std3)
      expect(result.success?).to be(false)
      expect(result.errors.flat_map(&:codes)).to include("V6")
    end

    it "can disable individual checks" do
      lenient = UTS46::Config.new(
        check_bidi: false, check_hyphens: false, check_joiners: false,
        verify_dns_length: false
      )
      expect(UTS46.to_ascii("0\u00E0.\u05D0", config: lenient).success?).to be(true)
      expect(UTS46.to_ascii("-a-.com", config: lenient).success?).to be(true)
      expect(UTS46.to_ascii("a\u200Cb", config: lenient).success?).to be(true)
      expect(UTS46.to_ascii("a..com", config: lenient).success?).to be(true)
    end
  end

  describe "error reporting" do
    it "reports which labels failed, with their index and status codes" do
      result = UTS46.to_ascii("example.\u0301.com")
      expect(result.success?).to be(false)
      expect(result.errors.length).to eq(1)
      error = result.errors.first
      expect(error).to be_a(UTS46::LabelError)
      expect(error.label).to eq("\u0301")
      expect(error.index).to eq(1)
      expect(error.codes).to include("V5")
    end

    it "reports errors for ToUnicode as well as ToASCII" do
      result = UTS46.to_unicode("xn--u-ccb.example")
      expect(result.success?).to be(false)
      expect(result.errors.first.index).to eq(0)
      expect(result.errors.first.codes).to include("V1")
    end

    it "returns a Result that never raises for bad input" do
      expect { UTS46.to_ascii("xn--0.pt") }.not_to raise_error
      expect(UTS46.to_ascii("xn--0.pt").success?).to be(false)
    end

    it "raises InvalidDomainError from to_ascii! with label details" do
      expect { UTS46.to_ascii!("xn--0.pt") }.to raise_error(
        UTS46::InvalidDomainError
      ) { |error|
        expect(error.errors.first.codes).to include("P4")
      }
    end

    it "returns the string form from the bang variants on success" do
      expect(UTS46.to_ascii!("b\u00FCcher.de")).to eq("xn--bcher-kva.de")
      expect(UTS46.to_unicode!("xn--bcher-kva.de")).to eq("b\u00FCcher.de")
    end

    it "still produces output for domains that fail validation" do
      result = UTS46.to_ascii("\u{0301}example.com")
      expect(result.success?).to be(false)
      expect(result.output).to be_a(String)
    end
  end

  describe "ACE label verification" do
    it "does not accept a label merely because it decodes as Punycode" do
      # "xn--0" fails Punycode decoding outright.
      expect(UTS46.to_unicode("xn--0.pt").errors.flat_map(&:codes)).to(
        include("P4")
      )
      # "xn--u-ccb" decodes, but the decoding is not NFC.
      expect(UTS46.to_unicode("xn--u-ccb").errors.flat_map(&:codes)).to(
        include("V1")
      )
      # "xn--a" decodes to a disallowed code point.
      expect(UTS46.to_unicode("xn--a.pt").errors.flat_map(&:codes)).to(
        include("V6")
      )
    end

    it "keeps the original label when ACE verification fails" do
      expect(UTS46.to_unicode("xn--0.pt").output).to eq("xn--0.pt")
      expect(UTS46.to_ascii("xn--0.pt").output).to eq("xn--0.pt")
    end

    it "round-trips valid ACE labels" do
      result = UTS46.to_unicode("xn--bcher-kva.de")
      expect(result.success?).to be(true)
      expect(result.output).to eq("b\u00FCcher.de")
    end
  end

  describe "ContextO rules" do
    it "requires MIDDLE DOT to be surrounded by 'l'" do
      expect(UTS46.to_ascii("l\u00B7l.com").success?).to be(true)
      result = UTS46.to_ascii("a\u00B7b.com")
      expect(result.errors.flat_map(&:codes)).to include("C3")
    end

    it "requires GREEK KERAIA to be followed by a Greek character" do
      expect(UTS46.to_ascii("\u0375\u03B1.com").success?).to be(true)
      result = UTS46.to_ascii("\u0375a.com")
      expect(result.errors.flat_map(&:codes)).to include("C4")
    end

    it "requires HEBREW GERESH/GERSHAYIM to follow a Hebrew character" do
      expect(UTS46.to_ascii("\u05D0\u05F3.com").success?).to be(true)
      result = UTS46.to_ascii("a\u05F3.com")
      expect(result.errors.flat_map(&:codes)).to include("C5")
      result = UTS46.to_ascii("a\u05F4.com")
      expect(result.errors.flat_map(&:codes)).to include("C6")
    end

    it "requires KATAKANA MIDDLE DOT to appear with Japanese characters" do
      expect(UTS46.to_ascii("\u30A2\u30FB\u30A4.com").success?).to be(true)
      result = UTS46.to_ascii("ab\u30FB.com")
      expect(result.errors.flat_map(&:codes)).to include("C7")
    end

    it "forbids mixing ARABIC-INDIC and EXTENDED ARABIC-INDIC digits" do
      expect(UTS46.to_ascii("\u0627\u0660\u0661.com").success?).to be(true)
      result = UTS46.to_ascii("\u0627\u0660\u06F1.com")
      expect(result.errors.flat_map(&:codes)).to include("C8")
    end
  end

  describe "Addressable::IDNA integration" do
    it "keeps the default interface working without a config" do
      expect(Addressable::IDNA.to_ascii("www.\u{8A79}\u{59C6}\u{65AF}.com")).to(
        eq("www.xn--8ws00zhy3a.com")
      )
      expect(Addressable::IDNA.to_unicode("www.xn--8ws00zhy3a.com")).to(
        eq("www.\u{8A79}\u{59C6}\u{65AF}.com")
      )
    end

    it "uses UTS #46 when a config is given" do
      expect(
        Addressable::IDNA.to_ascii("fa\u00DF.de", config: UTS46::TRANSITIONAL)
      ).to eq("fass.de")
      expect(
        Addressable::IDNA.to_ascii("fa\u00DF.de", config: UTS46::NONTRANSITIONAL)
      ).to eq("xn--fa-hia.de")
      expect(
        Addressable::IDNA.to_unicode("xn--fa-hia.de", config: UTS46::NONTRANSITIONAL)
      ).to eq("fa\u00DF.de")
    end

    it "raises for invalid domains when a config is given" do
      expect {
        Addressable::IDNA.to_ascii("xn--0.pt", config: UTS46::NONTRANSITIONAL)
      }.to raise_error(UTS46::InvalidDomainError)
    end
  end

  describe "Addressable::URI integration" do
    before do
      # Other specs reload Addressable::IDNA from source (dropping any
      # constants defined outside pure.rb), so make sure the UTS46
      # module and its data tables are present under the current
      # Addressable::IDNA.
      unless defined?(::Addressable::IDNA::UTS46::MAPPING) &&
             defined?(::Addressable::IDNA::Punycode)
        load "addressable/idna/punycode.rb"
        load "addressable/idna/uts46_data.rb"
        load "addressable/idna/uts46.rb"
      end
    end

    after do
      Addressable::URI.idna_config = nil
    end

    it "normalizes hosts with the legacy IDNA path by default" do
      expect(Addressable::URI.idna_config).to be_nil
      expect(Addressable::URI.parse("http://fa\u00DF.de/").normalize.to_s).to(
        eq("http://xn--fa-hia.de/")
      )
    end

    it "normalizes hosts with an explicitly selected UTS #46 configuration" do
      Addressable::URI.idna_config = UTS46::TRANSITIONAL
      expect(Addressable::URI.parse("http://fa\u00DF.de/").normalize.to_s).to(
        eq("http://fass.de/")
      )
      Addressable::URI.idna_config = UTS46::NONTRANSITIONAL
      expect(Addressable::URI.parse("http://fa\u00DF.de/").normalize.to_s).to(
        eq("http://xn--fa-hia.de/")
      )
    end

    it "uses the configuration for display_uri too" do
      Addressable::URI.idna_config = UTS46::NONTRANSITIONAL
      expect(Addressable::URI.parse("http://xn--fa-hia.de/").display_uri.to_s).to(
        eq("http://fa\u00DF.de/")
      )
    end

    it "falls back to the legacy conversion for invalid hosts" do
      Addressable::URI.idna_config = UTS46::NONTRANSITIONAL
      expect {
        Addressable::URI.parse("http://xn--0.pt/").normalize
      }.not_to raise_error
    end
  end
end
