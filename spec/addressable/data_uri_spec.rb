# frozen_string_literal: true

require "spec_helper"

require "addressable/uri"
require "stringio"

describe Addressable::URI::Data do
  it "parses the default media type, parameters, and payload" do
    uri = Addressable::URI.parse("data:,Hello%20World!")

    expect(uri).to be_a(described_class)
    expect(uri.media_type).to eq("text/plain")
    expect(uri.parameters).to eq("charset" => "US-ASCII")
    expect(uri.base64?).to eq(false)
    expect(uri.content_type).to eq("text/plain;charset=US-ASCII")
    expect(uri.data).to eq("Hello World!")
  end

  it "parses explicit media types and parameters" do
    uri = Addressable::URI.parse(
      "data:image/png;name=attachment;base64,AAE="
    )

    expect(uri.media_type).to eq("image/png")
    expect(uri.parameters).to eq("name" => "attachment")
    expect(uri.base64?).to eq(true)
    expect(uri.data.bytes).to eq([0, 1])
  end

  it "accepts an uppercase data scheme and quoted parameters" do
    uri = Addressable::URI.parse("DATA:;name=\"a;b\",x")

    expect(uri.scheme).to eq("data")
    expect(uri.parameters["name"]).to eq("a;b")
    expect(uri.data).to eq("x")
  end

  it "rejects non-ASCII bytes without percent encoding" do
    expect do
      described_class.parse("data:,é")
    end.to raise_error(Addressable::URI::InvalidDataURIError)
  end

  it "preserves binary content decoded all at once or from two-character chunks" do
    binary = (0..255).map(&:chr).join.force_encoding(Encoding::ASCII_8BIT)
    uri = described_class.new(
      :media_type => "application/octet-stream",
      :data => binary,
      :base64 => true
    )

    expect(uri.data.b).to eq(binary)

    chunks = uri.to_s.each_char.each_slice(2).map(&:join)
    decoded = String.new.force_encoding(Encoding::ASCII_8BIT)
    metadata = nil
    described_class.decode(chunks) do |chunk, decoder|
      decoded << chunk
      metadata = decoder
    end

    expect(decoded.b).to eq(binary)
    expect(metadata.media_type).to eq("application/octet-stream")
    expect(metadata.base64).to eq(true)
  end

  it "streams percent triples that span chunk boundaries" do
    chunks = ["data:text/plain,%", "0", "0%", "F", "F"]
    output = StringIO.new

    size = described_class.decode(chunks, output)

    expect(size).to eq(2)
    expect(output.string.bytes).to eq([0, 255])
  end

  it "streams base64 quads that span chunk boundaries" do
    chunks = ["data:;base64,A", "A", "E", "="]

    expect(described_class.decode(chunks)).to eq("\x00\x01".b)
  end

  it "keeps the default media type marker in base64 serialization" do
    uri = described_class.new(:data => "x", :base64 => true)

    expect(uri.to_s).to eq("data:;base64,eA==")
    expect(uri.to_s(:base64)).to eq("data:;base64,eA==")
  end

  it "streams directly from an IO" do
    source = StringIO.new("data:application/octet-stream;base64,AAE=")
    output = StringIO.new

    described_class.decode(source, output)

    expect(output.string.bytes).to eq([0, 1])
  end

  it "rejects incomplete percent tails" do
    expect { described_class.decode("data:,%0") }.to raise_error(
      Addressable::URI::InvalidDataURIError
    )
  end

  it "rejects illegal percent digits" do
    expect { described_class.decode("data:,%zz") }.to raise_error(
      Addressable::URI::InvalidDataURIError
    )
  end

  it "rejects incomplete base64 tails" do
    expect { described_class.decode("data:;base64,AAE") }.to raise_error(
      Addressable::URI::InvalidDataURIError
    )
  end

  it "rejects illegal base64 encoding" do
    expect { described_class.decode("data:;base64,AAEE=") }.to raise_error(
      Addressable::URI::InvalidDataURIError
    )
  end

  it "stops once decoded data exceeds the requested size limit" do
    source_chunks = ["data:,%00", "%01%02"]
    read_chunks = 0
    chunks = Enumerator.new do |yielder|
      source_chunks.each do |chunk|
        read_chunks += 1
        yielder << chunk
      end
    end

    expect do
      described_class.decode(chunks, nil, :max_bytes => 1)
    end.to raise_error(Addressable::URI::DataURITooLargeError)
    expect(read_chunks).to eq(2)
  end

  it "serializes percent encoded data" do
    uri = described_class.new(
      :media_type => "application/octet-stream",
      :data => "\x00\xff".b,
      :base64 => true
    )

    expect(uri.to_s(:percent)).to eq(
      "data:application/octet-stream,%00%FF"
    )
  end

  it "serializes base64 encoded data" do
    uri = described_class.new(
      :media_type => "application/octet-stream",
      :data => "\x00\x01".b
    )

    expect(uri.to_s(:base64)).to eq(
      "data:application/octet-stream;base64,AAE="
    )
  end
end
