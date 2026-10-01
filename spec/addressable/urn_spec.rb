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

require "addressable/urn"
require "addressable/uri"

describe Addressable::URN do
  describe ".parse" do
    it "returns nil for nil" do
      expect(Addressable::URN.parse(nil)).to eq(nil)
    end

    it "parses a minimal URN" do
      urn = Addressable::URN.parse("urn:isbn:0451450523")
      expect(urn).to be_kind_of(Addressable::URN)
      expect(urn.scheme).to eq("urn")
      expect(urn.nid).to eq("isbn")
      expect(urn.nss).to eq("0451450523")
      expect(urn.r_component).to eq(nil)
      expect(urn.q_component).to eq(nil)
      expect(urn.fragment).to eq(nil)
    end

    it "accepts a two-character NID" do
      urn = Addressable::URN.parse("urn:ab:nss")
      expect(urn.nid).to eq("ab")
    end

    it "accepts a 32-character NID with internal hyphens" do
      nid = "a" + ("b-" * 15) + "c"
      expect(nid.length).to eq(32)
      urn = Addressable::URN.parse("urn:#{nid}:nss")
      expect(urn.nid).to eq(nid)
    end

    it "rejects a 33-character NID" do
      nid = "a" * 33
      expect { Addressable::URN.parse("urn:#{nid}:nss") }
        .to raise_error(Addressable::URN::InvalidURNError)
    end

    it "is a kind of Addressable::URI" do
      urn = Addressable::URN.parse("urn:isbn:0451450523")
      expect(urn).to be_kind_of(Addressable::URI)
      expect(urn.absolute?).to eq(true)
    end

    it "parses an r-component" do
      urn = Addressable::URN.parse("urn:example:foo?+svc=x")
      expect(urn.r_component).to eq("svc=x")
      expect(urn.q_component).to eq(nil)
    end

    it "parses a q-component" do
      urn = Addressable::URN.parse("urn:example:foo?=key=value")
      expect(urn.r_component).to eq(nil)
      expect(urn.q_component).to eq("key=value")
    end

    it "parses r- and q-components and an f-component" do
      urn = Addressable::URN.parse(
        "urn:example:foo?+resolver?=query#section-2")
      expect(urn.nss).to eq("foo")
      expect(urn.r_component).to eq("resolver")
      expect(urn.q_component).to eq("query")
      expect(urn.fragment).to eq("section-2")
      expect(urn.f_component).to eq("section-2")
    end

    it "preserves separators percent-encoded inside components" do
      urn = Addressable::URN.parse(
        "urn:example:a%2Fb?+r%3D%3f?=q%3D%3d#f%2Frag")
      expect(urn.nss).to eq("a%2Fb")
      expect(urn.r_component).to eq("r%3D%3f")
      expect(urn.q_component).to eq("q%3D%3d")
      expect(urn.fragment).to eq("f%2Frag")
    end

    it "allows literal ?+ and ?= inside component content" do
      urn = Addressable::URN.parse(
        "urn:example:nss?+r%3d?+x?=q?=y")
      expect(urn.nss).to eq("nss")
      expect(urn.r_component).to eq("r%3d?+x")
      expect(urn.q_component).to eq("q?=y")
    end

    it "exposes components through the generic URI API" do
      urn = Addressable::URN.parse(
        "urn:example:foo?+res?=que#frag")
      expect(urn.path).to eq("example:foo")
      expect(urn.query).to eq("?+res?=que")
      expect(urn.fragment).to eq("frag")
      expect(urn.host).to eq(nil)
    end

    it "rejects a non-urn scheme" do
      expect { Addressable::URN.parse("http://example.com/x") }
        .to raise_error(Addressable::URN::InvalidURNError)
    end

    it "rejects a URN without an NSS" do
      expect { Addressable::URN.parse("urn:isbn:") }
        .to raise_error(Addressable::URN::InvalidURNError)
    end

    it "rejects the reserved 'urn' NID" do
      expect { Addressable::URN.parse("urn:urn:nss") }
        .to raise_error(Addressable::URN::InvalidURNError)
    end

    it "rejects an invalid NID" do
      expect { Addressable::URN.parse("urn:a:nss") }
        .to raise_error(Addressable::URN::InvalidURNError)
      expect { Addressable::URN.parse("urn:ab-:nss") }
        .to raise_error(Addressable::URN::InvalidURNError)
      expect { Addressable::URN.parse("urn:has spaces:nss") }
        .to raise_error(Addressable::URN::InvalidURNError)
    end

    it "rejects malformed percent-encoding" do
      expect { Addressable::URN.parse("urn:isbn:nss%zz") }
        .to raise_error(Addressable::URN::InvalidURNError)
    end

    it "rejects empty r/q-components" do
      expect { Addressable::URN.parse("urn:isbn:nss?+") }
        .to raise_error(Addressable::URN::InvalidURNError)
      expect { Addressable::URN.parse("urn:isbn:nss?=") }
        .to raise_error(Addressable::URN::InvalidURNError)
    end

    it "allows an empty f-component" do
      urn = Addressable::URN.parse("urn:isbn:nss#")
      expect(urn.fragment).to eq("")
      expect(urn.to_s).to eq("urn:isbn:nss#")
    end
  end
  describe ".new" do
    it "builds a URN from named components" do
      urn = Addressable::URN.new(
        :nid => "isbn", :nss => "0451450523",
        :r_component => "svc=x", :q_component => "k=v",
        :f_component => "frag")
      expect(urn.scheme).to eq("urn")
      expect(urn.nid).to eq("isbn")
      expect(urn.nss).to eq("0451450523")
      expect(urn.r_component).to eq("svc=x")
      expect(urn.q_component).to eq("k=v")
      expect(urn.fragment).to eq("frag")
      expect(urn.to_s)
        .to eq("urn:isbn:0451450523?+svc=x?=k=v#frag")
    end

    it "accepts :f_component as an alias for :fragment" do
      urn = Addressable::URN.new(
        :nid => "ns", :nss => "s", :f_component => "f")
      expect(urn.fragment).to eq("f")
    end

    it "does not reject an empty URN" do
      urn = Addressable::URN.new
      expect(urn.to_s).to eq("")
      expect(urn.nid).to eq(nil)
    end

    it "rejects specifying both a path and NID/NSS" do
      expect {
        Addressable::URN.new(:nid => "ns", :path => "ns:s")
      }.to raise_error(ArgumentError)
    end

    it "rejects specifying both a query and r/q-components" do
      expect {
        Addressable::URN.new(:nid => "ns", :nss => "s",
          :r_component => "r", :query => "?=q")
      }.to raise_error(ArgumentError)
    end

    it "rejects an authority" do
      expect {
        Addressable::URN.new(:nid => "ns", :nss => "s", :host => "h")
      }.to raise_error(Addressable::URN::InvalidURNError)
    end
  end

  describe "component writers" do
    let(:urn) { Addressable::URN.parse("urn:isbn:0451450523") }

    it "updates the NID and NSS" do
      urn.nid = "issn"
      urn.nss = "1234-5678"
      expect(urn.to_s).to eq("urn:issn:1234-5678")
    end

    it "adds, updates and removes r/q-components" do
      urn.r_component = "a"
      expect(urn.to_s).to eq("urn:isbn:0451450523?+a")
      urn.q_component = "b"
      expect(urn.to_s).to eq("urn:isbn:0451450523?+a?=b")
      urn.r_component = nil
      expect(urn.to_s).to eq("urn:isbn:0451450523?=b")
      expect(urn.r_component).to eq(nil)
      urn.q_component = nil
      expect(urn.to_s).to eq("urn:isbn:0451450523")
    end

    it "supports short r/q/f accessors" do
      urn.r = "res"
      urn.q = "que"
      urn.f = "frag"
      expect(urn.r).to eq("res")
      expect(urn.q).to eq("que")
      expect(urn.f).to eq("frag")
    end

    it "rejects invalid NSS content" do
      expect { urn.nss = "a/b?c" }
        .to raise_error(Addressable::URN::InvalidURNError)
    end

    it "rejects non-string components" do
      expect { urn.nss = 42 }
        .to raise_error(TypeError)
    end
  end
 
  describe "#normalize" do
    it "lowercases scheme and NID but never the NSS" do
      urn = Addressable::URN.parse("urn:ISBN:AbCdEf")
      normalized = urn.normalize
      expect(normalized.nid).to eq("isbn")
      expect(normalized.nss).to eq("AbCdEf")
      expect(normalized.to_s).to eq("urn:isbn:AbCdEf")
    end

    it "upcases percent-encoding hex in every component" do
      urn = Addressable::URN.parse(
        "urn:isbn:a%2fb?+r%3d?=q%2f#f%2f")
      normalized = urn.normalize
      expect(normalized.nss).to eq("a%2Fb")
      expect(normalized.r_component).to eq("r%3D")
      expect(normalized.q_component).to eq("q%2F")
      expect(normalized.fragment).to eq("f%2F")
    end

    it "does not decode or re-encode the NSS" do
      urn = Addressable::URN.parse("urn:isbn:a%3ab%2Fc")
      expect(urn.normalize.nss).to eq("a%3Ab%2Fc")
    end

    it "returns an Addressable::URN" do
      urn = Addressable::URN.parse("urn:isbn:0451450523")
      expect(urn.normalize).to be_kind_of(Addressable::URN)
    end
  end

  describe "lexical equivalence" do
    it "is equivalent across NID case and percent-hex case" do
      a = Addressable::URN.parse("urn:ISBN:a%2fb%2fc")
      b = Addressable::URN.parse("urn:isbn:a%2Fb%2Fc")
      expect(a).to be_lexically_equivalent(b)
    end

    it "ignores r/q/f-components for resource identity" do
      a = Addressable::URN.parse("urn:example:a%2Fb")
      b = Addressable::URN.parse(
        "urn:EXAMPLE:a%2fb?+res?=que#frag")
      expect(a).to be_same_resource(b)
      expect(a).to be_same_urn(b)
      expect(a.lexically_equivalent?(b.to_s)).to eq(true)
    end

    it "does not treat a raw separator as equivalent to encoded" do
      a = Addressable::URN.parse("urn:example:a/b")
      b = Addressable::URN.parse("urn:example:a%2Fb")
      expect(a.lexically_equivalent?(b)).to eq(false)
    end

    it "preserves NSS case for unknown namespaces" do
      a = Addressable::URN.parse("urn:example:AbC")
      b = Addressable::URN.parse("urn:example:abc")
      expect(a.lexically_equivalent?(b)).to eq(false)
    end

    it "returns false for non-URN inputs" do
      a = Addressable::URN.parse("urn:example:s")
      expect(a.lexically_equivalent?("http://example.com/")).to eq(false)
      expect(a.lexically_equivalent?("not a urn")).to eq(false)
      expect(a.lexically_equivalent?(nil)).to eq(false)
    end

    it "keeps == sensitive to r/q/f-components" do
      a = Addressable::URN.parse("urn:example:a")
      b = Addressable::URN.parse("urn:example:a?=q")
      expect(a == b).to eq(false)
      expect(a.same_resource?(b)).to eq(true)
    end
  end
 
  describe "namespace normalization rules" do
    after do
      Addressable::URN.unregister_namespace("isbn")
    end

    it "applies a registered rule to the NSS" do
      Addressable::URN.register_namespace("isbn") do |urn|
        urn.nss.delete("-")
      end
      urn = Addressable::URN.parse("urn:ISBN:0-451-45052-3")
      expect(urn.normalize.to_s).to eq("urn:isbn:0451450523")
    end

    it "matches registered NIDs case-insensitively" do
      Addressable::URN.register_namespace(:isbn) { |u| u.nss.upcase }
      expect(Addressable::URN.parse("urn:isbn:abc").normalize.nss)
        .to eq("ABC")
    end

    it "removes a rule with unregister_namespace" do
      Addressable::URN.register_namespace("isbn") { |u| u.nss.delete("-") }
      Addressable::URN.unregister_namespace("ISBN")
      expect(Addressable::URN.parse("urn:isbn:0-451").normalize.nss)
        .to eq("0-451")
    end

    it "performs only minimal processing for unknown namespaces" do
      urn = Addressable::URN.parse("urn:unknown:0-451%2fab")
      expect(urn.normalize.to_s).to eq("urn:unknown:0-451%2Fab")
    end

    it "rejects a non-callable rule" do
      expect { Addressable::URN.register_namespace("x", 42) }
        .to raise_error(ArgumentError)
    end
  end

  describe "round trips" do
    it "preserves percent-encoded separators through a round trip" do
      string = "urn:example:a%2Fb%3F%23c?+r%2F%3F%3D?=q%3F%3D%23#f%2F%23"
      urn = Addressable::URN.parse(string)
      expect(urn.to_s).to eq(string)
      reparsed = Addressable::URN.parse(urn.to_s)
      expect(reparsed.nss).to eq(urn.nss)
      expect(reparsed.r_component).to eq(urn.r_component)
      expect(reparsed.q_component).to eq(urn.q_component)
      expect(reparsed.fragment).to eq(urn.fragment)
    end

    it "round-trips component content containing ?+ and ?=" do
      string = "urn:example:nss?+r%3d?+x?=q?=y"
      urn = Addressable::URN.parse(string)
      expect(urn.to_s).to eq(string)
      expect(Addressable::URN.parse(urn.to_s).r_component)
        .to eq("r%3d?+x")
    end

    it "round-trips through the generic URI representation" do
      urn = Addressable::URN.parse(
        "urn:example:foo?+res?=que?=inside#frag")
      generic = Addressable::URI.parse(urn.to_s)
      rebuilt = Addressable::URN.new(
        :scheme => generic.scheme,
        :path => generic.path,
        :query => generic.query,
        :fragment => generic.fragment)
      expect(rebuilt.r_component).to eq(urn.r_component)
      expect(rebuilt.q_component).to eq(urn.q_component)
      expect(rebuilt.to_s).to eq(urn.to_s)
      expect(rebuilt).to eq(urn)
    end
  end

  describe "generic URI compatibility" do
    it "is parseable as a generic Addressable::URI" do
      string = "urn:example:foo?+r?=q#f"
      generic = Addressable::URI.parse(string)
      expect(generic.scheme).to eq("urn")
      expect(generic.path).to eq("example:foo")
      expect(generic.query).to eq("+r?=q")
      expect(generic.fragment).to eq("f")
    end

    it "can be compared with a generic URI carrying a URN" do
      urn = Addressable::URN.parse("urn:example:a%2Fb")
      generic = Addressable::URI.parse("urn:EXAMPLE:a%2fb")
      expect(urn.same_resource?(generic)).to eq(true)
    end

    it "supports dup" do
      urn = Addressable::URN.parse("urn:example:s?+r#f")
      copy = urn.dup
      expect(copy).to be_kind_of(Addressable::URN)
      expect(copy.to_s).to eq(urn.to_s)
      copy.nss = "t"
      expect(urn.nss).to eq("s")
    end
  end

  describe "#omit" do
    let(:urn) do
      Addressable::URN.parse("urn:example:s?+r?=q#f")
    end

    it "omits r/q/f components" do
      expect(urn.omit(:r).to_s).to eq("urn:example:s?=q#f")
      expect(urn.omit(:q).to_s).to eq("urn:example:s?+r#f")
      expect(urn.omit(:f).to_s).to eq("urn:example:s?+r?=q")
      expect(urn.omit(:r, :q, :f).to_s)
        .to eq("urn:example:s")
    end

    it "refuses to omit the NID or NSS" do
      expect { urn.omit(:nid) }.to raise_error(ArgumentError)
      expect { urn.omit(:nss) }.to raise_error(ArgumentError)
    end

    it "rejects unknown component names" do
      expect { urn.omit(:bogus) }.to raise_error(ArgumentError)
    end
  end
end 
