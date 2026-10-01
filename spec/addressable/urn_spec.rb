# frozen_string_literal: true

require "spec_helper"

require "addressable/urn"
require "uri"

describe Addressable::URN, "RFC 8141 parsing" do
  let(:urn_string) do
    "urn:EXAMPLE:Resource%2FOne?+r%3D%2B?=q%3D%23#frag%2F1"
  end

  subject(:urn) { Addressable::URI.parse(urn_string) }

  it "parses URNs from the generic URI parser" do
    expect(urn).to be_a(Addressable::URN)
  end

  it "exposes each RFC 8141 component separately" do
    expect(urn.nid).to eq("EXAMPLE")
    expect(urn.nss).to eq("Resource%2FOne")
    expect(urn.r_component).to eq("r%3D%2B")
    expect(urn.q_component).to eq("q%3D%23")
    expect(urn.fragment).to eq("frag%2F1")
  end

  it "keeps encoded component delimiters encoded on a round trip" do
    expect(urn.to_s).to eq(urn_string)
  end

  it "preserves the generic URI API representation" do
    expect(urn.scheme).to eq("urn")
    expect(urn.path).to eq("EXAMPLE:Resource%2FOne")
    expect(urn.query).to eq("+r%3D%2B?=q%3D%23")
    expect(Addressable::URN.new(
      :nid => "example",
      :nss => "Resource%2FOne",
      :r_component => "r%3D%2B",
      :q_component => "q%3D%23",
      :fragment => "frag%2F1"
    ).to_s).to eq("urn:example:Resource%2FOne?+r%3D%2B?=q%3D%23#frag%2F1")
  end

  it "does not confuse an encoded query delimiter with a q-component" do
    encoded_equals = Addressable::URN.parse(
      "urn:example:nss?+value%3D%23"
    )
    expect(encoded_equals.r_component).to eq("value%3D%23")
    expect(encoded_equals.q_component).to be_nil

    encoded_question = Addressable::URN.parse(
      "urn:example:nss?=value%3F%2B%23"
    )
    expect(encoded_question.r_component).to be_nil
    expect(encoded_question.q_component).to eq("value%3F%2B%23")
  end

  it "rejects malformed percent encoding" do
    expect do
      Addressable::URN.parse("urn:example:Resource%2")
    end.to raise_error(Addressable::URN::InvalidURNError)
  end

  it "rejects an empty fragment component" do
    expect do
      Addressable::URN.parse("urn:example:resource#")
    end.to raise_error(Addressable::URN::InvalidURNError)
  end

  it "allows empty resolution and query components" do
    r_only = Addressable::URN.parse("urn:example:resource?+")
    q_only = Addressable::URN.parse("urn:example:resource?=")

    expect(r_only.r_component).to eq("")
    expect(r_only.q_component).to be_nil
    expect(q_only.r_component).to be_nil
    expect(q_only.q_component).to eq("")
  end

  it "rejects a non-URN scheme" do
    expect do
      Addressable::URN.parse("http://example.com/")
    end.to raise_error(Addressable::URN::InvalidURNError)
  end

  it "accepts URNs parsed by the standard library URI class" do
    standard_urn = URI.parse(urn_string)
    expect(Addressable::URN.parse(standard_urn)).to be_a(Addressable::URN)
  end
end

describe Addressable::URN, "lexical equivalence" do
  let(:urn_string) do
    "urn:EXAMPLE:Resource%2FOne?+r%52%3D%2B?=q%3D%23#frag%2F1"
  end

  subject(:urn) { Addressable::URN.parse(urn_string) }

  let(:equivalent_string) do
    "URN:example:Resource%2FOne?+r%52%3d%2b?=q%3d%23#frag%2f1"
  end

  it "lowercases only the scheme and NID and uppercases percent triplets" do
    expect(urn.normalize.to_s).to eq(
      "urn:example:Resource%2FOne?+rR%3D%2B?=q%3D%23#frag%2F1"
    )
  end

  it "compares complete URNs lexically" do
    expect(urn.lexically_equivalent?(equivalent_string)).to be(true)
    expect(urn.equivalent?(Addressable::URN.parse(equivalent_string))).to be(true)
    expect(urn === equivalent_string).to be(true)
  end

  it "preserves NSS letter case" do
    different_case = "urn:example:resource%2fone?+r%52%3d%2b?=q%3d%23#frag%2f1"
    expect(urn.lexically_equivalent?(different_case)).to be(false)
  end

  it "does not lexically identify URNs with different added components" do
    without_fragment = "urn:example:Resource%2FOne?+r%52%3d%2b?=q%3d%23"
    expect(urn.lexically_equivalent?(without_fragment)).to be(false)
  end
end

describe Addressable::URN, "resource identity" do
  subject(:urn) do
    Addressable::URN.parse(
      "urn:EXAMPLE:Resource%2FOne?+resolution?=query#fragment"
    )
  end

  it "identifies only the normalized scheme, NID, and NSS" do
    expect(urn.resource_identifier).to eq("urn:example:Resource%2FOne")
  end

  it "ignores r-component, q-component, and fragment" do
    same_resource = "urn:example:Resource%2FOne?+other?=data#other"
    expect(urn.same_resource?(same_resource)).to be(true)
  end

  it "does not lowercase NSS by default" do
    expect(urn.same_resource?("urn:example:resource%2fone")).to be(false)
  end
end

describe Addressable::URN, "registered namespace normalization" do
  after do
    Addressable::URN.namespace_normalizers.delete("urn-spec-example")
  end

  it "uses registered rules for the NSS and keeps components distinct" do
    Addressable::URN.register_namespace("urn-spec-example") do |nss|
      nss.downcase
    end

    urn = Addressable::URN.parse(
      "URN:URN-SPEC-EXAMPLE:Resource%2FName?+r?=q#f"
    )

    expect(urn.resource_identifier).to eq(
      "urn:urn-spec-example:resource%2fname"
    )
    expect(urn.normalize.to_s).to eq(
      "urn:urn-spec-example:resource%2fname?+r?=q#f"
    )
  end

  it "requires a normalization block" do
    expect do
      Addressable::URN.register_namespace("example")
    end.to raise_error(ArgumentError)
  end
end

describe Addressable::URN, "mutable URN components" do
  subject(:urn) do
    Addressable::URN.new(
      :nid => "example",
      :nss => "resource",
      :r_component => "resolution",
      :q_component => "query"
    )
  end

  it "updates dedicated and generic component views together" do
    urn.nid = "OTHER"
    urn.nss = "Resource%2FName"
    urn.r_component = nil
    urn.q_component = "Query%3F%2B"

    expect(urn.path).to eq("OTHER:Resource%2FName")
    expect(urn.r_component).to be_nil
    expect(urn.q_component).to eq("Query%3F%2B")
    expect(urn.query).to eq("=Query%3F%2B")
    expect(urn.to_s).to eq("urn:OTHER:Resource%2FName?=Query%3F%2B")
  end

  it "cannot change the URN scheme" do
    expect { urn.scheme = "http" }.to raise_error(
      Addressable::URN::InvalidURNError
    )
  end

  it "validates fragments assigned after construction" do
    expect { urn.fragment = "a#b" }.to raise_error(
      Addressable::URN::InvalidURNError
    )
  end

  it "does not change components when assigning an invalid r-component" do
    expect do
      urn.r_component = "a#b"
    end.to raise_error(Addressable::URN::InvalidURNError)

    expect(urn.r_component).to eq("resolution")
    expect(urn.q_component).to eq("query")
    expect(urn.to_s).to eq(
      "urn:example:resource?+resolution?=query"
    )
  end
end
