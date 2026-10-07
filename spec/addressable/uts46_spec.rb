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
require "json"

require "addressable/idna"
require "addressable/idna/uts46"

# The pure-Ruby IDNA spec reloads Addressable::IDNA with remove_const +
# load, which also drops Addressable::IDNA::UTS46. Reload the UTS 46
# implementation (and the mode dispatch) when that has happened.
RSpec.configure do |config|
  config.before do |example|
    unless defined?(Addressable::IDNA::UTS46)
      load "addressable/idna/punycode.rb"
      load "addressable/idna/uts46/tables.rb"
      load "addressable/idna/uts46.rb"
      load "addressable/idna.rb"
    end
  end
end

describe Addressable::IDNA::UTS46 do
  it "is pinned to Unicode 15.1.0 data" do
    expect(Addressable::IDNA::UTS46::UNICODE_VERSION).to eq("15.1.0")
  end

  describe "deviation characters" do
    it "keeps ß in nontransitional mode" do
      expect(Addressable::IDNA::UTS46.to_ascii("faß.de")).to eq("xn--fa-hia.de")
    end

    it "maps ß to ss in transitional mode" do
      expect(Addressable::IDNA::UTS46.to_ascii("faß.de", transitional: true)).to eq("fass.de")
    end

    it "maps ẞ to ss in both modes (Unicode 15.1 mapping)" do
      expect(Addressable::IDNA::UTS46.to_ascii("faẞ.de")).to eq("fass.de")
      expect(Addressable::IDNA::UTS46.to_ascii("faẞ.de", transitional: true)).to eq("fass.de")
    end

    it "keeps final sigma in nontransitional mode" do
      expect(Addressable::IDNA::UTS46.to_ascii("βόλος.gr")).to eq("xn--nxasmm1c.gr")
    end

    it "maps final sigma to sigma in transitional mode" do
      expect(Addressable::IDNA::UTS46.to_ascii("βόλος.gr", transitional: true)).to eq(
        Addressable::IDNA::UTS46.to_ascii("βόλοσ.gr", transitional: true)
      )
    end

    it "decodes xn--fa-hia.de to faß.de" do
      expect(Addressable::IDNA::UTS46.to_unicode("xn--fa-hia.de")).to eq("faß.de")
    end
  end

  describe "mapping and normalization" do
    it "maps fullwidth characters" do
      expect(Addressable::IDNA::UTS46.to_ascii("ＡＢＣ.example")).to eq("abc.example")
    end

    it "maps ideographic dots to ASCII dots" do
      expect(Addressable::IDNA::UTS46.to_ascii("www。example。com")).to eq("www.example.com")
      expect(Addressable::IDNA::UTS46.to_ascii("www．example．com")).to eq("www.example.com")
      expect(Addressable::IDNA::UTS46.to_ascii("www｡example｡com")).to eq("www.example.com")
    end

    it "drops ignored code points" do
      expect(Addressable::IDNA::UTS46.to_ascii("a­b.example")).to eq("ab.example")
    end

    it "normalizes to NFC" do
      expect(Addressable::IDNA::UTS46.to_ascii("éxample.com")).to eq("xn--xample-9ua.com")
    end

    it "lowercases ASCII" do
      expect(Addressable::IDNA::UTS46.to_ascii("EXAMPLE.COM")).to eq("example.com")
    end
  end

  describe "STD3 ASCII rules" do
    it "allows underscore without STD3 rules" do
      expect(Addressable::IDNA::UTS46.to_ascii("exa_mple.com")).to eq("exa_mple.com")
    end

    it "rejects underscore with STD3 rules" do
      expect do
        Addressable::IDNA::UTS46.to_ascii("exa_mple.com", use_std3_ascii_rules: true)
      end.to raise_error(Addressable::IDNA::UTS46::Error) do |error|
        expect(error.rule).to eq(:disallowed_codepoint)
        expect(error.label).to eq("exa_mple")
      end
    end

    it "rejects space with STD3 rules" do
      expect do
        Addressable::IDNA::UTS46.to_ascii("a b.com", use_std3_ascii_rules: true)
      end.to raise_error(Addressable::IDNA::UTS46::Error)
    end

    it "allows space without STD3 rules" do
      expect(Addressable::IDNA::UTS46.to_ascii("a b.com")).to eq("a b.com")
    end
  end

  describe "label length checks" do
    it "accepts a 63 character label" do
      label = "a" * 63
      expect(Addressable::IDNA::UTS46.to_ascii("#{label}.com")).to eq("#{label}.com")
    end

    it "rejects a 64 character label" do
      label = "a" * 64
      expect do
        Addressable::IDNA::UTS46.to_ascii("#{label}.com")
      end.to raise_error(Addressable::IDNA::UTS46::Error) do |error|
        expect(error.rule).to eq(:label_too_long)
        expect(error.label).to eq(label)
      end
    end

    it "rejects a label whose A-label form exceeds 63 octets" do
      expect do
        Addressable::IDNA::UTS46.to_ascii("ü" * 60 + ".de")
      end.to raise_error(Addressable::IDNA::UTS46::Error) do |error|
        expect(error.rule).to eq(:label_too_long)
      end
    end

    it "accepts an overlong label when verify_dns_length is false" do
      label = "a" * 64
      expect(Addressable::IDNA::UTS46.to_ascii("#{label}.com", verify_dns_length: false)).to eq(
        "#{label}.com"
      )
    end

    it "rejects a domain name that is too long" do
      domain = (["a" * 63] * 4).join(".") + ".com"
      expect do
        Addressable::IDNA::UTS46.to_ascii(domain)
      end.to raise_error(Addressable::IDNA::UTS46::Error) do |error|
        expect(error.rule).to eq(:domain_too_long)
      end
    end
  end

  describe "empty labels and root dot" do
    it "rejects an empty domain" do
      expect do
        Addressable::IDNA::UTS46.to_ascii("")
      end.to raise_error(Addressable::IDNA::UTS46::Error) do |error|
        expect(error.rule).to eq(:empty_domain)
      end
    end

    it "rejects empty labels" do
      expect do
        Addressable::IDNA::UTS46.to_ascii("a..b")
      end.to raise_error(Addressable::IDNA::UTS46::Error) do |error|
        expect(error.rule).to eq(:empty_label)
      end
    end

    it "allows empty labels when verify_dns_length is false" do
      expect(Addressable::IDNA::UTS46.to_ascii("a..b", verify_dns_length: false)).to eq("a..b")
    end

    it "preserves a trailing root dot" do
      expect(Addressable::IDNA::UTS46.to_ascii("example.com.")).to eq("example.com.")
      expect(Addressable::IDNA::UTS46.to_ascii("bücher.de.")).to eq("xn--bcher-kva.de.")
    end
  end

  describe "hyphen rules" do
    it "rejects labels with leading or trailing hyphens" do
      expect do
        Addressable::IDNA::UTS46.to_ascii("-abc.com")
      end.to raise_error(Addressable::IDNA::UTS46::Error) { |e| expect(e.rule).to eq(:hyphen) }
      expect do
        Addressable::IDNA::UTS46.to_ascii("abc-.com")
      end.to raise_error(Addressable::IDNA::UTS46::Error) { |e| expect(e.rule).to eq(:hyphen) }
    end

    it "rejects labels with hyphens in the 3rd and 4th positions" do
      expect do
        Addressable::IDNA::UTS46.to_ascii("ab--cd.com")
      end.to raise_error(Addressable::IDNA::UTS46::Error) { |e| expect(e.rule).to eq(:hyphen) }
    end

    it "permits hyphen violations when check_hyphens is false" do
      expect(Addressable::IDNA::UTS46.to_ascii("-abc.com", check_hyphens: false)).to eq("-abc.com")
    end
  end

  describe "leading combining marks" do
    it "rejects a label starting with a combining mark" do
      expect do
        Addressable::IDNA::UTS46.to_ascii("́abc.example")
      end.to raise_error(Addressable::IDNA::UTS46::Error) do |error|
        expect(error.rule).to eq(:leading_combining_mark)
        expect(error.position).to eq(0)
      end
    end
  end

  describe "NFC requirement" do
    it "rejects an A-label that decodes to a non-NFC label" do
      # "xn--e-xbb" decodes to "e" + U+0301 (NFD of é)
      expect do
        Addressable::IDNA::UTS46.to_ascii("xn--e-xbb.com")
      end.to raise_error(Addressable::IDNA::UTS46::Error) do |error|
        expect(error.rule).to eq(:nfc)
      end
    end
  end

  describe "existing A-labels (xn--)" do
    it "validates and re-encodes valid A-labels" do
      expect(Addressable::IDNA::UTS46.to_ascii("xn--bcher-kva.de")).to eq("xn--bcher-kva.de")
      expect(Addressable::IDNA::UTS46.to_ascii("XN--BCHER-KVA.de")).to eq("xn--bcher-kva.de")
    end

    it "rejects an A-label with no punycode content" do
      expect do
        Addressable::IDNA::UTS46.to_ascii("xn--.com")
      end.to raise_error(Addressable::IDNA::UTS46::Error) { |e| expect(e.rule).to eq(:invalid_alabel) }
    end

    it "rejects an A-label whose punycode ends with a hyphen" do
      expect do
        Addressable::IDNA::UTS46.to_ascii("xn--a-.com")
      end.to raise_error(Addressable::IDNA::UTS46::Error) { |e| expect(e.rule).to eq(:invalid_alabel) }
    end

    it "rejects an A-label decoding to a disallowed code point" do
      expect do
        Addressable::IDNA::UTS46.to_ascii("xn--a.com")
      end.to raise_error(Addressable::IDNA::UTS46::Error) { |e| expect(e.rule).to eq(:disallowed_codepoint) }
    end

    it "rejects an A-label decoding to a mapped code point" do
      # "xn--kkg" decodes to U+1E9E, which is a mapped (not valid)
      # code point in Unicode 15.1, so it is not a valid A-label.
      expect do
        Addressable::IDNA::UTS46.to_ascii("xn--kkg.de")
      end.to raise_error(Addressable::IDNA::UTS46::Error) { |e| expect(e.rule).to eq(:disallowed_codepoint) }
    end

    it "rejects invalid punycode" do
      expect do
        Addressable::IDNA::UTS46.to_ascii("xn--zckp1cyg1.sblo.jp")
      end.to raise_error(Addressable::IDNA::UTS46::Error) { |e| expect(e.rule).to eq(:invalid_alabel) }
    end

    it "keeps invalid A-labels as-is in to_unicode (never fails)" do
      expect(Addressable::IDNA::UTS46.to_unicode("xn--.com")).to eq("xn--.com")
      expect(Addressable::IDNA::UTS46.to_unicode("xn--a-.com")).to eq("xn--a-.com")
      expect(Addressable::IDNA::UTS46.to_unicode("xn--a.com")).to eq("xn--a.com")
      expect(Addressable::IDNA::UTS46.to_unicode("xn--zckp1cyg1.sblo.jp")).to eq(
        "xn--zckp1cyg1.sblo.jp"
      )
    end
  end

  describe "Unicode 15.1.0 data" do
    it "accepts CJK Extension I ideographs added in Unicode 15.1" do
      expect(Addressable::IDNA::UTS46.to_ascii("\u{2EBF0}.example")).to eq("xn--8g0n.example")
      expect(Addressable::IDNA::UTS46.to_ascii("\u{2EE5D}.example")).to eq("xn--zy0n.example")
    end

    it "rejects ideographic description characters added in Unicode 15.1" do
      expect do
        Addressable::IDNA::UTS46.to_ascii("\u{2FFC}.example")
      end.to raise_error(Addressable::IDNA::UTS46::Error) { |e| expect(e.rule).to eq(:disallowed_codepoint) }
      expect do
        Addressable::IDNA::UTS46.to_ascii("\u{31EF}.example")
      end.to raise_error(Addressable::IDNA::UTS46::Error) { |e| expect(e.rule).to eq(:disallowed_codepoint) }
    end

    it "rejects code points only assigned in Unicode 16.0" do
      expect do
        Addressable::IDNA::UTS46.to_ascii("\u{10D50}.example")
      end.to raise_error(Addressable::IDNA::UTS46::Error) { |e| expect(e.rule).to eq(:disallowed_codepoint) }
      expect do
        Addressable::IDNA::UTS46.to_ascii("\u{1CCF0}.example")
      end.to raise_error(Addressable::IDNA::UTS46::Error) { |e| expect(e.rule).to eq(:disallowed_codepoint) }
    end

    it "maps U+1E9E to 'ss' as specified up to Unicode 15.1" do
      expect(Addressable::IDNA::UTS46.to_ascii("fa\u{1E9E}.de")).to eq("fass.de")
      expect(Addressable::IDNA::UTS46.to_ascii("fa\u{1E9E}.de", transitional: true)).to eq("fass.de")
    end
  end

  describe "error reporting" do
    it "identifies the offending label and rule" do
      expect do
        Addressable::IDNA::UTS46.to_ascii("ok.exa_mple.com", use_std3_ascii_rules: true)
      end.to raise_error(Addressable::IDNA::UTS46::Error) do |error|
        expect(error.rule).to eq(:disallowed_codepoint)
        expect(error.label).to eq("exa_mple")
        expect(error.message).to include("exa_mple")
        expect(error.message).to include("disallowed_codepoint")
      end
    end

    it "identifies the position of a disallowed code point" do
      expect do
        Addressable::IDNA::UTS46.to_ascii("ab\u0378cd.example")
      end.to raise_error(Addressable::IDNA::UTS46::Error) do |error|
        expect(error.rule).to eq(:disallowed_codepoint)
        expect(error.label).to eq("ab\u0378cd")
        expect(error.position).to eq(2)
      end
    end

    it "rejects unknown options" do
      expect do
        Addressable::IDNA::UTS46.to_ascii("example.com", bogus: true)
      end.to raise_error(ArgumentError)
    end

    it "rejects invalid UTF-8 input" do
      expect do
        Addressable::IDNA::UTS46.to_ascii("ex\xFFmple.com".b)
      end.to raise_error(Addressable::IDNA::UTS46::Error) { |e| expect(e.rule).to eq(:invalid_input) }
    end
  end
end

describe Addressable::IDNA, "UTS 46 mode" do
  it "keeps IDNA2003-compatible behavior as the default mode" do
    expect(Addressable::IDNA.to_ascii("faß.de")).to eq("xn--fa-hia.de")
    expect(Addressable::IDNA.to_ascii("faß.de", mode: :idna2003)).to eq("xn--fa-hia.de")
  end

  it "dispatches to UTS 46 processing with mode: :uts46" do
    expect(Addressable::IDNA.to_ascii("faß.de", mode: :uts46)).to eq("xn--fa-hia.de")
    expect(Addressable::IDNA.to_ascii("faß.de", mode: :uts46, transitional: true)).to eq("fass.de")
    expect(Addressable::IDNA.to_unicode("xn--fa-hia.de", mode: :uts46)).to eq("faß.de")
  end

  it "passes UTS 46 options through" do
    expect do
      Addressable::IDNA.to_ascii("exa_mple.com", mode: :uts46, use_std3_ascii_rules: true)
    end.to raise_error(Addressable::IDNA::UTS46::Error)
    expect(Addressable::IDNA.to_ascii("exa_mple.com", mode: :uts46)).to eq("exa_mple.com")
  end

  it "rejects unknown modes" do
    expect do
      Addressable::IDNA.to_ascii("example.com", mode: :idna2008)
    end.to raise_error(ArgumentError)
  end

  it "exposes the pinned Unicode version" do
    expect(Addressable::IDNA::UTS46::UNICODE_VERSION).to eq("15.1.0")
  end
end

describe "UTS 46 oracle vectors (spec/fixtures/uts46_vectors.jsonl)" do
  vectors_path = File.expand_path("../../fixtures/uts46_vectors.jsonl", __FILE__)
  vectors = File.readlines(vectors_path, chomp: true).map { |line| JSON.parse(line) }

  vectors.each do |direction, transitional, std3, input, expected|
    options = { use_std3_ascii_rules: std3 }
    options[:transitional] = transitional unless transitional.nil?
    description = "#{direction} #{input.inspect} (transitional=#{transitional.inspect}, std3=#{std3})"

    if direction == "ascii"
      it description do
        if expected == "ERROR"
          expect do
            Addressable::IDNA::UTS46.to_ascii(input, **options)
          end.to raise_error(Addressable::IDNA::UTS46::Error)
        else
          expect(Addressable::IDNA::UTS46.to_ascii(input, **options)).to eq(expected)
        end
      end
    else
      it description do
        expect(Addressable::IDNA::UTS46.to_unicode(input, **options)).to eq(expected)
      end
    end
  end
end

describe "Unicode IdnaTestV2.txt (official Unicode 15.1 vectors)" do
  idnatest_path = File.expand_path("../../fixtures/IdnaTestV2.txt", __FILE__)

  if File.exist?(idnatest_path)
    File.foreach(idnatest_path).with_index(1) do |line, lineno|
      line = line.strip
      next if line.empty? || line.start_with?("#")
      type, source, to_unicode_expected, to_ascii_expected, = line.split(";").map(&:strip)
      to_unicode_expected = to_ascii_expected if to_unicode_expected.to_s.empty?
      to_ascii_expected = to_unicode_expected if to_ascii_expected.to_s.empty?
      transitional_modes =
        case type
        when "T" then [true]
        when "N" then [false]
        else [true, false]
        end

      it "line #{lineno}: #{source.inspect}" do
        # The ToUnicode column of transitional (T) lines is computed
        # with transitional mapping.
        expect(
          Addressable::IDNA::UTS46.to_unicode(source, transitional: type == "T")
        ).to eq(to_unicode_expected)
        transitional_modes.each do |transitional|
          if to_ascii_expected.start_with?("[")
            expect do
              Addressable::IDNA::UTS46.to_ascii(source, transitional: transitional)
            end.to raise_error(Addressable::IDNA::UTS46::Error)
          else
            expect(
              Addressable::IDNA::UTS46.to_ascii(source, transitional: transitional)
            ).to eq(to_ascii_expected)
          end
        end
      end
    end
  else
    it "runs when spec/fixtures/IdnaTestV2.txt is present" do
      skip(
        "Download IdnaTestV2.txt for Unicode 15.1.0 from " +        "https://www.unicode.org/Public/idna/15.1.0/IdnaTestV2.txt into " +        "spec/fixtures/ to run the official Unicode test vectors."
      )
    end
  end
end
