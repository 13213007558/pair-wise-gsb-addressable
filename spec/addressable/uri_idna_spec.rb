# frozen_string_literal: true

require "spec_helper"
require "addressable/idna"
require "addressable/uri"

RSpec.describe Addressable::URI, "IDNA normalization" do
  it "preserves the legacy default normalization behavior" do
    uri = described_class.parse("http://Faß.de/")
    expect(uri.normalize.to_s).to eq("http://xn--fa-hia.de/")
  end

  it "allows explicit nontransitional UTS #46 normalization" do
    uri = described_class.parse("http://Faß.de/")
    expect(uri.normalize(Addressable::IDNA::STRICT_PROFILE).to_s).to eq(
      "http://xn--fa-hia.de/"
    )
  end

  it "raises and identifies the invalid label with an explicit profile" do
    uri = described_class.parse("http://good.ex_ample.com/")
    result = Addressable::IDNA::STRICT_PROFILE.to_ascii(uri.host)
    expect(result).not_to be_success
    expect(result.errors_by_label).to eq(1 => [:disallowed_std3])
    expect do
      uri.normalize!(Addressable::IDNA::STRICT_PROFILE)
    end.to raise_error(Addressable::IDNA::IdnaError)
  end

  it "supports an independently configured display profile" do
    profile = Addressable::IDNA::Profile.new
    uri = described_class.parse("http://xn--fa-hia.de/")
    expect(uri.display_uri(profile).host).to eq("faß.de")
  end
end
