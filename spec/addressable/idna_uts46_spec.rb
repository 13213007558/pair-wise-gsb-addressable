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

require "addressable/idna"

UTS46 = Addressable::IDNA::UTS46

def uts46_ascii(domain, **options)
  UTS46.to_ascii(domain, **options)
end

def uts46_error(domain, **options)
  UTS46.to_ascii(domain, **options)
  nil
rescue Addressable::IDNA::UTS46::Error => error
  error
end

describe Addressable::IDNA::UTS46 do
  it "is pinned to Unicode 15.1" do
    expect(UTS46::UNICODE_VERSION).to eq("15.1.0")
  end

  describe "mapping and basic conversion" do
    it "passes plain ASCII through unchanged" do
      expect(uts46_ascii("www.google.com")).to eq("www.google.com")
    end

    it "lowercases ASCII" do
      expect(uts46_ascii("WWW.GOOGLE.COM")).to eq("www.google.com")
    end

    it "converts non-ASCII labels with punycode" do
      expect(uts46_ascii("www.詹姆斯.com")).to eq("www.xn--8ws00zhy3a.com")
      expect(uts46_ascii("café.com")).to eq("xn--caf-dma.com")
      expect(uts46_ascii("βόλος.com")).to eq("xn--nxasmm1c.com")
    end

    it "applies case folding and compatibility mappings" do
      expect(uts46_ascii("ＡＢＣ.com")).to eq("abc.com")
      expect(uts46_ascii("ﬀ.com")).to eq("ff.com")
      expect(uts46_ascii("①.com")).to eq("1.com")
      expect(uts46_ascii("Å.com")).to eq("xn--5ca.com")
      expect(uts46_ascii("ℂ.com")).to eq("c.com")
      expect(uts46_ascii("Ⅳ.com")).to eq("iv.com")
    end

    it "maps Cherokee lowercase to the original uppercase letters" do
      expect(uts46_ascii("ꭰ.com")).to eq("xn--58d.com")
      expect(uts46_ascii("Ꭰ.com")).to eq("xn--58d.com")
    end

    it "removes default-ignorable characters" do
      expect(uts46_ascii("a\u{00AD}b.com")).to eq("ab.com")
      expect(uts46_ascii("a\u{200B}b.com")).to eq("ab.com")
      expect(uts46_ascii("a\u{FEFF}b.com")).to eq("ab.com")
    end

    it "maps dot-like characters to the ASCII full stop" do
      expect(uts46_ascii("a。b")).to eq("a.b")
      expect(uts46_ascii("a．b")).to eq("a.b")
      expect(uts46_ascii("a｡b")).to eq("a.b")
    end

    it "rejects mappings that would produce a dot" do
      expect(uts46_error("🄀.com").rule).to eq(:disallowed)
      expect(uts46_error("․.com").rule).to eq(:disallowed)
    end

    it "rejects disallowed code points" do
      expect(uts46_error("a\u{0000}b.com").rule).to eq(:disallowed)
      expect(uts46_error("a\u{FDD0}b.com").rule).to eq(:disallowed)
      expect(uts46_error("a\u{E000}b.com").rule).to eq(:disallowed)
      expect(uts46_error("ﷺ.com").rule).to eq(:disallowed)
      expect(uts46_error("a\u{061C}b.com").rule).to eq(:disallowed)
    end

    it "rejects code points assigned after Unicode 15.1" do
      # U+1C89 CYRILLIC CAPITAL LETTER TJE was assigned in Unicode 16.0.
      expect(uts46_error("\u{1C89}.com").rule).to eq(:disallowed)
    end
  end

  describe "bidi rule (RFC 5893)" do
    it "accepts pure LTR, RTL and digit labels" do
      expect(uts46_ascii("abc.com")).to eq("abc.com")
      expect(uts46_ascii("123.com")).to eq("123.com")
      expect(uts46_ascii("אב.com")).to eq("xn--4dbc.com")
      expect(uts46_ascii("אב1.com")).to eq("xn--4db0c.com")
      expect(uts46_ascii("ב١.com")).to eq("xn--jeb4c.com")
    end

    it "rejects RTL characters in LTR labels" do
      expect(uts46_error("aא.com").rule).to eq(:bidi)
      expect(uts46_error("aאב.com").rule).to eq(:bidi)
      expect(uts46_error("a١.com").rule).to eq(:bidi)
    end

    it "rejects LTR characters in RTL labels" do
      expect(uts46_error("אa.com").rule).to eq(:bidi)
      expect(uts46_error("אבa.com").rule).to eq(:bidi)
    end

    it "requires the first character to be L, R or AL" do
      expect(uts46_error("1א.com").rule).to eq(:bidi)
      expect(uts46_error("١א.com").rule).to eq(:bidi)
      expect(uts46_error("١.com").rule).to eq(:bidi)
    end

    it "rejects mixed Arabic-Indic and extended Arabic-Indic digits" do
      expect(uts46_error("א١1.com").rule).to eq(:bidi)
      expect(uts46_error("א1١.com").rule).to eq(:bidi)
    end

    it "enforces the end-of-label rules" do
      expect(uts46_error("א·.com").rule).to eq(:bidi)
      expect(uts46_ascii("אְ.com")).to eq("xn--7cb7d.com")
    end

    it "can be disabled" do
      expect(uts46_ascii("aא.com", check_bidi: false)).to eq("xn--a-0hc.com")
    end
  end


  describe "deviations and transitional processing" do
    it "keeps ß under nontransitional processing" do
      expect(uts46_ascii("faß.de")).to eq("xn--fa-hia.de")
      expect(uts46_ascii("straße.de")).to eq("xn--strae-oqa.de")
    end

    it "maps ß to ss under transitional processing" do
      expect(uts46_ascii("faß.de", transitional: true)).to eq("fass.de")
      expect(uts46_ascii("straße.de", transitional: true)).to eq("strasse.de")
    end

    it "maps ẞ to ß (single-pass mapping) in both modes" do
      expect(uts46_ascii("ẞ.de")).to eq("xn--zca.de")
      expect(uts46_ascii("ẞ.de", transitional: true)).to eq("xn--zca.de")
    end

    it "handles final sigma as a deviation" do
      expect(uts46_ascii("ς.com")).to eq("xn--3xa.com")
      expect(uts46_ascii("ς.com", transitional: true)).to eq("xn--4xa.com")
      expect(uts46_ascii("σ.com")).to eq("xn--4xa.com")
    end

    it "removes ZWNJ and ZWJ under transitional processing" do
      expect(uts46_ascii("a\u{200C}b.com", transitional: true)).to eq("ab.com")
      expect(uts46_ascii("a\u{200D}b.com", transitional: true)).to eq("ab.com")
    end

    it "keeps joiners under nontransitional processing when valid" do
      expect(uts46_ascii("ل‌ل.com")).to eq("xn--ghba319q.com")
      expect(uts46_ascii("क्‍ष.com")).to eq("xn--11b2ezcw70k.com")
    end
  end

  describe "STD3 rules" do
    it "rejects non-LDH ASCII by default" do
      expect(uts46_error("a_b.com").rule).to eq(:std3)
      expect(uts46_error("a b.com").rule).to eq(:std3)
    end

    it "allows non-LDH ASCII when STD3 rules are off" do
      expect(uts46_ascii("a_b.com", use_std3_rules: false)).to eq("a_b.com")
      expect(uts46_ascii("a b.com", use_std3_rules: false)).to eq("a b.com")
    end

    it "rejects disallowed_STD3_mapped characters only with STD3 on" do
      expect(uts46_error("a .com").rule).to eq(:std3)
      expect(uts46_ascii("a .com", use_std3_rules: false)).to eq("a .com")
      expect(uts46_ascii("a＿.com", use_std3_rules: false)).to eq("a_.com")
    end
  end

  describe "hyphen checks" do
    it "rejects leading and trailing hyphens" do
      expect(uts46_error("-a.com").rule).to eq(:hyphen)
      expect(uts46_error("a-.com").rule).to eq(:hyphen)
    end

    it "rejects hyphens in the 3rd and 4th positions" do
      expect(uts46_error("ab--cd.com").rule).to eq(:hyphen)
      expect(uts46_error("ab--.com").rule).to eq(:hyphen)
    end

    it "allows hyphens elsewhere" do
      expect(uts46_ascii("a-b.com")).to eq("a-b.com")
      expect(uts46_ascii("ab--cd.com", check_hyphens: false)).to eq("ab--cd.com")
    end
  end
