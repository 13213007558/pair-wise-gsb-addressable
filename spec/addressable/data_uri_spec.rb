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

require "addressable/data_uri"
require "stringio"

# An IO-like source that never returns more than two bytes per read,
# forcing percent-encoded triplets and base64 quads to span chunks.
class TwoByteReader
  attr_reader :bytes_read

  def initialize(string)
    @string = string
    @offset = 0
    @bytes_read = 0
  end

  def read(_length)
    return nil if @offset >= @string.bytesize
    chunk = @string.byteslice(@offset, 2)
    @offset += chunk.bytesize
    @bytes_read += chunk.bytesize
    chunk
  end
end

describe Addressable::DataURI do
  let(:binary_payload) { (0..255).to_a.pack("C*") * 4 }

  def binary_io
    StringIO.new(String.new.b)
  end

  describe ".parse" do
    it "parses the media type, parameters and base64 marker" do
      uri = described_class.parse(
        "data:image/png;name=logo;base64,iVBORw0KGgo="
      )
      expect(uri.media_type).to eq("image/png")
      expect(uri.params).to eq("name" => "logo")
      expect(uri.base64?).to eq(true)
      expect(uri.data).to eq("\x89PNG\r\n\x1A\n".b)
    end

    it "defaults to text/plain;charset=US-ASCII" do
      uri = described_class.parse("data:,Hello%20World")
      expect(uri.media_type).to eq("text/plain")
      expect(uri.params).to eq("charset" => "US-ASCII")
      expect(uri.charset).to eq("US-ASCII")
      expect(uri.base64?).to eq(false)
      expect(uri.data).to eq("Hello World")
    end

    it "applies defaults when only the base64 marker is present" do
      uri = described_class.parse("data:;base64,SGVsbG8sIFdvcmxkIQ==")
      expect(uri.media_type).to eq("text/plain")
      expect(uri.charset).to eq("US-ASCII")
      expect(uri.data).to eq("Hello, World!")
    end

    it "accepts the scheme and base64 marker case-insensitively" do
      uri = described_class.parse("DATA:Text/Plain;BASE64,aGk=")
      expect(uri.media_type).to eq("text/plain")
      expect(uri.base64?).to eq(true)
      expect(uri.data).to eq("hi")
    end

    it "downcases parameter names but preserves values" do
      uri = described_class.parse("data:text/plain;Charset=UTF-8,x")
      expect(uri.params).to eq("charset" => "UTF-8")
    end

    it "returns a copy when passed a DataURI" do
      original = described_class.parse("data:,x")
      copy = described_class.parse(original)
      expect(copy).not_to be(original)
      expect(copy.to_s).to eq(original.to_s)
    end

    it "returns nil when passed nil" do
      expect(described_class.parse(nil)).to be_nil
    end

    it "rejects URIs with a different scheme" do
      expect do
        described_class.parse("http://example.com/")
      end.to raise_error(Addressable::DataURI::InvalidDataURIError)
    end

    it "rejects data URIs without a comma" do
      expect do
        described_class.parse("data:text/plain")
      end.to raise_error(Addressable::DataURI::InvalidDataURIError)
    end

    it "rejects malformed parameters" do
      expect do
        described_class.parse("data:text/plain;oops,x")
      end.to raise_error(Addressable::DataURI::InvalidDataURIError)
    end

    it "rejects invalid media types" do
      expect do
        described_class.new(media_type: "not a media type")
      end.to raise_error(Addressable::DataURI::InvalidDataURIError)
    end
  end

  describe "#data" do
    it "decodes percent-encoded payloads" do
      uri = described_class.parse("data:,A%20B%25C")
      expect(uri.data).to eq("A B%C")
    end

    it "decodes base64 payloads" do
      uri = described_class.parse("data:application/octet-stream;base64,AAEC/f7/")
      expect(uri.data).to eq("\x00\x01\x02\xfd\xfe\xff".b)
    end

    it "returns binary strings" do
      uri = described_class.parse("data:;base64,AAEC/f7/")
      expect(uri.data.encoding).to eq(Encoding::BINARY)
    end
  end

  describe "strict validation" do
    it "rejects invalid percent-encoded sequences" do
      expect do
        described_class.parse("data:,%ZZ").data
      end.to raise_error(Addressable::DataURI::InvalidDataURIError)
    end

    it "rejects incomplete percent-encoded sequences at end of input" do
      expect do
        described_class.parse("data:,abc%4").data
      end.to raise_error(Addressable::DataURI::InvalidDataURIError)
    end

    it "rejects a lone percent sign at end of input" do
      expect do
        described_class.parse("data:,abc%").data
      end.to raise_error(Addressable::DataURI::InvalidDataURIError)
    end

    it "rejects characters outside the base64 alphabet" do
      expect do
        described_class.parse("data:;base64,QUJ!").data
      end.to raise_error(Addressable::DataURI::InvalidDataURIError)
    end

    it "rejects whitespace inside base64 data" do
      expect do
        described_class.parse("data:;base64,QUJD RA==").data
      end.to raise_error(Addressable::DataURI::InvalidDataURIError)
    end

    it "rejects incomplete base64 quads at end of input" do
      expect do
        described_class.parse("data:;base64,QUI").data
      end.to raise_error(Addressable::DataURI::InvalidDataURIError)
    end

    it "rejects data after base64 padding" do
      expect do
        described_class.parse("data:;base64,QQ==QQ==").data
      end.to raise_error(Addressable::DataURI::InvalidDataURIError)
    end

    it "rejects misplaced base64 padding" do
      expect do
        described_class.parse("data:;base64,QU=D").data
      end.to raise_error(Addressable::DataURI::InvalidDataURIError)
    end
  end

  describe ".decode_stream" do
    it "decodes base64 input read two bytes at a time" do
      encoded = [binary_payload].pack("m0")
      output = binary_io
      described_class.decode_stream(
        TwoByteReader.new(encoded), output, base64: true
      )
      expect(output.string).to eq(binary_payload)
    end

    it "decodes percent-encoded input read two bytes at a time" do
      encoded = described_class.percent_encode(binary_payload)
      output = binary_io
      described_class.decode_stream(
        TwoByteReader.new(encoded), output, base64: false
      )
      expect(output.string).to eq(binary_payload)
    end

    it "matches the one-shot result for base64 input" do
      encoded = [binary_payload].pack("m0")
      one_shot = described_class.parse(
        "data:application/octet-stream;base64,#{encoded}"
      ).data
      output = binary_io
      described_class.decode_stream(
        TwoByteReader.new(encoded), output, base64: true
      )
      expect(output.string).to eq(one_shot)
    end

    it "matches the one-shot result for percent-encoded input" do
      encoded = described_class.percent_encode(binary_payload)
      one_shot = described_class.parse(
        "data:application/octet-stream,#{encoded}"
      ).data
      output = binary_io
      described_class.decode_stream(
        TwoByteReader.new(encoded), output, base64: false
      )
      expect(output.string).to eq(one_shot)
    end

    it "returns the number of decoded bytes" do
      encoded = [binary_payload].pack("m0")
      written = described_class.decode_stream(
        TwoByteReader.new(encoded), binary_io, base64: true
      )
      expect(written).to eq(binary_payload.bytesize)
    end

    it "detects incomplete tails even when chunked" do
      expect do
        described_class.decode_stream(
          TwoByteReader.new("QUJ"), binary_io, base64: true
        )
      end.to raise_error(Addressable::DataURI::InvalidDataURIError)
    end

    context "with a size limit" do
      it "stops reading and raises once the limit is exceeded" do
        encoded = [binary_payload].pack("m0")
        reader = TwoByteReader.new(encoded)
        expect do
          described_class.decode_stream(
            reader, binary_io, base64: true, limit: 100
          )
        end.to raise_error(Addressable::DataURI::PayloadTooLargeError)
        expect(reader.bytes_read).to be < encoded.bytesize
      end

      it "does not write beyond the limit" do
        encoded = [binary_payload].pack("m0")
        output = binary_io
        expect do
          described_class.decode_stream(
            TwoByteReader.new(encoded), output, base64: true, limit: 100
          )
        end.to raise_error(Addressable::DataURI::PayloadTooLargeError)
        expect(output.string.bytesize).to be <= 100
      end

      it "accepts payloads within the limit" do
        encoded = [binary_payload].pack("m0")
        output = binary_io
        expect do
          described_class.decode_stream(
            TwoByteReader.new(encoded), output,
            base64: true, limit: binary_payload.bytesize
          )
        end.not_to raise_error
        expect(output.string).to eq(binary_payload)
      end
    end
  end

  describe "#decode_to" do
    it "decodes its own payload into an IO" do
      uri = described_class.parse("data:;base64,SGVsbG8sIFdvcmxkIQ==")
      output = binary_io
      expect(uri.decode_to(output)).to eq(13)
      expect(output.string).to eq("Hello, World!")
    end

    it "enforces the size limit" do
      uri = described_class.parse("data:;base64,SGVsbG8sIFdvcmxkIQ==")
      expect do
        uri.decode_to(binary_io, limit: 5)
      end.to raise_error(Addressable::DataURI::PayloadTooLargeError)
    end
  end

  describe "#to_s" do
    it "serializes percent-encoded payloads" do
      uri = described_class.new(media_type: "text/plain", data: "hi there")
      expect(uri.to_s).to eq("data:text/plain,hi%20there")
    end

    it "serializes base64 payloads" do
      uri = described_class.new(
        media_type: "text/plain", data: "hi there", base64: true
      )
      expect(uri.to_s).to eq("data:text/plain;base64,aGkgdGhlcmU=")
    end

    it "percent-encodes bytes that are not legal in a URI" do
      uri = described_class.new(data: "%#\r\n")
      expect(uri.to_s).to eq("data:text/plain,%25%23%0D%0A")
    end

    it "round-trips through parse" do
      uri = described_class.new(
        media_type: "image/png",
        params: { "name" => "logo" },
        data: binary_payload,
        base64: true
      )
      parsed = described_class.parse(uri.to_s)
      expect(parsed.media_type).to eq("image/png")
      expect(parsed.params).to eq("name" => "logo")
      expect(parsed.base64?).to eq(true)
      expect(parsed.data).to eq(binary_payload)
    end

    it "can switch a parsed base64 URI to percent-encoding" do
      uri = described_class.parse("data:text/plain;base64,aGkgdGhlcmU=")
      expect(uri.to_s(base64: false)).to eq("data:text/plain,hi%20there")
    end

    it "can switch a parsed percent-encoded URI to base64" do
      uri = described_class.parse("data:text/plain,hi%20there")
      expect(uri.to_s(base64: true)).to eq("data:text/plain;base64,aGkgdGhlcmU=")
    end

    it "preserves the original encoding by default" do
      string = "data:text/plain;base64,aGk="
      expect(described_class.parse(string).to_s).to eq(string)
    end
  end

  describe "#data=" do
    it "replaces the payload" do
      uri = described_class.parse("data:,old")
      uri.data = "new"
      expect(uri.data).to eq("new")
      expect(uri.to_s).to eq("data:text/plain;charset=US-ASCII,new")
    end
  end
end
