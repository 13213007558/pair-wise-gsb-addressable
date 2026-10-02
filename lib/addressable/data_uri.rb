# frozen_string_literal: true

#--
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
#++

require "stringio"

module Addressable
  ##
  # This is an implementation of a <code>data:</code> URI parser and
  # serializer based on
  # <a href="http://www.ietf.org/rfc/rfc2397.txt">RFC 2397</a>.
  #
  # Data URIs may carry large binary attachments. Decoding the whole
  # payload in one go would keep both the encoded and the decoded
  # representation in memory, so in addition to the usual one-shot
  # accessors, this class can decode a payload incrementally from any
  # IO-like source (anything responding to <code>read(length)</code>)
  # into any IO-like sink, without buffering more than a small window.
  # Percent-encoded triplets and base64 quads may span chunk boundaries.
  class DataURI
    ##
    # Raised if the data URI or its payload is malformed.
    class InvalidDataURIError < StandardError
    end

    ##
    # Raised if the decoded payload exceeds a caller-supplied size limit.
    class PayloadTooLargeError < StandardError
    end

    ##
    # The media type used when the mediatype portion of the URI is omitted.
    DEFAULT_MEDIA_TYPE = "text/plain"

    ##
    # The parameters implied when the mediatype portion of the URI is
    # omitted.
    DEFAULT_PARAMS = { "charset" => "US-ASCII" }.freeze

    ##
    # Matches a data URI, capturing the mediatype header and the payload.
    DATA_URI_PATTERN = /\Adata:([^,]*),(.*)\z/im

    ##
    # Characters allowed in a MIME token (RFC 2045).
    MIME_TOKEN_CHARACTERS = "A-Za-z0-9!#$%&'*+\-.^_`|~"

    ##
    # Matches a MIME token (RFC 2045).
    MIME_TOKEN = /\A[#{MIME_TOKEN_CHARACTERS}]+\z/

    ##
    # Matches a MIME media type: a type and subtype separated by a slash.
    MIME_MEDIA_TYPE =
      /\A[#{MIME_TOKEN_CHARACTERS}]+\/[#{MIME_TOKEN_CHARACTERS}]+\z/

    ##
    # A percent sign that is not followed by two hexadecimal digits.
    INVALID_PERCENT_SEQUENCE = /%(?![0-9A-Fa-f]{2})/

    ##
    # Characters that may not appear literally in a payload. Everything
    # else, including "%", "#", "?", whitespace and non-ASCII bytes, is
    # percent-encoded during serialization.
    PAYLOAD_SAFE = /[^A-Za-z0-9\-._~!$&'()*+,;=:@\/]/

    ##
    # All characters of the base64 alphabet (RFC 4648, section 4).
    BASE64_ALPHABET =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    ##
    # Matches a string consisting solely of base64 alphabet characters.
    BASE64_VALID_SEQUENCE = /\A[A-Za-z0-9+\/]*\z/

    ##
    # Lookup table mapping a byte to its base64 sextet, or nil when the
    # byte is not part of the base64 alphabet.
    BASE64_VALUES = Array.new(256).tap do |table|
      BASE64_ALPHABET.each_char.with_index do |char, index|
        table[char.ord] = index
      end
      table.freeze
    end

    ##
    # Number of bytes requested from the source on each read while
    # streaming. Sources may return fewer bytes than requested.
    READ_SIZE = 16 * 1024

    ##
    # Returns a DataURI object based on the parsed string.
    #
    # @param [String, Addressable::URI, #to_str] uri
    #   The data URI string to parse.
    #
    # @return [Addressable::DataURI] The parsed data URI.
    def self.parse(uri)
      return nil unless uri
      return uri.dup if uri.kind_of?(self)
      uri = uri.to_str if uri.respond_to?(:to_str)
      match = DATA_URI_PATTERN.match(uri.to_s)
      unless match
        raise InvalidDataURIError,
          "not a data URI: #{uri.to_s.inspect}"
      end

      segments = match.captures[0].split(";", -1)
      media_type = segments.shift
      payload = match.captures[1]

      base64 = false
      params = {}
      segments.each do |segment|
        if segment =~ /\Abase64\z/i
          base64 = true
        else
          name, separator, value = segment.partition("=")
          if name.empty? || separator.empty?
            raise InvalidDataURIError,
              "malformed parameter in data URI: #{segment.inspect}"
          end
          params[name.downcase] = value
        end
      end

      if media_type.nil? || media_type.empty?
        media_type = DEFAULT_MEDIA_TYPE
        params = DEFAULT_PARAMS.merge(params)
      end

      new(
        :media_type => media_type,
        :params => params,
        :encoded_data => payload,
        :base64 => base64
      )
    end

    ##
    # Decodes an encoded payload incrementally.
    #
    # Reads the encoded payload from +input+ in chunks, decodes it, and
    # writes the decoded bytes to +output+ as they become available.
    # Percent-encoded triplets and base64 quads may span chunk
    # boundaries, and sources are allowed to return fewer bytes than
    # requested on any read.
    #
    # @param [#read] input
    #   The source of the encoded payload. Must respond to
    #   <code>read(length)</code> and return nil or an empty String at
    #   end of input.
    # @param [#write] output
    #   The sink for the decoded bytes.
    # @param [Boolean] base64
    #   Whether the payload is base64-encoded. When false, the payload
    #   is treated as percent-encoded.
    # @param [Integer, nil] limit
    #   Maximum number of decoded bytes to accept. When the decoded
    #   payload exceeds this limit, a {PayloadTooLargeError} is raised
    #   and no further input is read.
    #
    # @return [Integer] The number of decoded bytes written.
    def self.decode_stream(input, output, base64:, limit: nil)
      total = 0
      emit = lambda do |bytes|
        unless bytes.empty?
          total += bytes.bytesize
          if limit && total > limit
            raise PayloadTooLargeError,
              "decoded payload exceeds the limit of #{limit} bytes"
          end
          output.write(bytes)
        end
      end
      if base64
        decode_base64_stream(input, &emit)
      else
        decode_percent_stream(input, &emit)
      end
      total
    end

    ##
    # Percent-encodes a binary payload for inclusion in a data URI.
    #
    # @param [String] data The decoded payload.
    #
    # @return [String] The percent-encoded payload.
    def self.percent_encode(data)
      data.b.gsub(PAYLOAD_SAFE) { |byte| format("%%%02X", byte.ord) }
    end

    ##
    # Decodes a chunk of percent-encoded data. The chunk must not end
    # with an incomplete triplet; use {.decode_stream} for input that
    # arrives in arbitrary chunks.
    def self.decode_percent_chunk(chunk)
      if (match = INVALID_PERCENT_SEQUENCE.match(chunk))
        raise InvalidDataURIError,
          "invalid percent-encoding at offset #{match.begin(0)}"
      end
      chunk.gsub(/%([0-9A-Fa-f]{2})/) { [Regexp.last_match(1)].pack("H2") }.b
    end
    private_class_method :decode_percent_chunk

    ##
    # Incrementally decodes a percent-encoded payload from +input+,
    # yielding decoded byte strings as they become available.
    def self.decode_percent_stream(input)
      pending = String.new
      while (chunk = input.read(READ_SIZE)) && !chunk.empty?
        buffer = pending + chunk
        keep = 0
        keep = 1 if buffer.end_with?("%")
        if keep.zero? && buffer.bytesize >= 2 &&
            buffer.getbyte(buffer.bytesize - 2) == 0x25
          keep = 2
        end
        pending = keep.zero? ? String.new : buffer[buffer.bytesize - keep, keep]
        region = keep.zero? ? buffer : buffer[0, buffer.bytesize - keep]
        yield decode_percent_chunk(region) unless region.empty?
      end
      unless pending.empty?
        raise InvalidDataURIError,
          "incomplete percent-encoded sequence at end of input"
      end
    end
    private_class_method :decode_percent_stream

    ##
    # Incrementally decodes a base64 payload from +input+, yielding
    # decoded byte strings as they become available.
    def self.decode_base64_stream(input)
      padded = false
      pending = String.new
      while (chunk = input.read(READ_SIZE)) && !chunk.empty?
        if padded
          raise InvalidDataURIError,
            "unexpected data after base64 padding"
        end
        buffer = pending + chunk
        keep = buffer.bytesize % 4
        region = keep.zero? ? buffer : buffer[0, buffer.bytesize - keep]
        pending = keep.zero? ? String.new : buffer[buffer.bytesize - keep, keep]
        next if region.empty?
        decoded, padded = decode_base64_region(region)
        yield decoded
      end
      unless pending.empty?
        raise InvalidDataURIError,
          "incomplete base64 data at end of input"
      end
    end
    private_class_method :decode_base64_stream

    ##
    # Decodes a string of complete base64 quads. Returns the decoded
    # bytes and whether terminal padding was encountered.
    def self.decode_base64_region(region)
      eq = region.index("=")
      if eq.nil?
        validate_base64_alphabet!(region)
        return [region.unpack("m").first, false]
      end
      quad_start = region.bytesize - 4
      if eq < quad_start
        raise InvalidDataURIError,
          "base64 padding is only allowed at the end of the payload"
      end
      bulk = region[0, quad_start]
      validate_base64_alphabet!(bulk)
      decoded = bulk.empty? ? String.new : bulk.unpack("m").first
      decoded << decode_base64_quad(region[quad_start, 4])
      [decoded, true]
    end
    private_class_method :decode_base64_region

    ##
    # Raises unless the string consists solely of base64 alphabet
    # characters.
    def self.validate_base64_alphabet!(string)
      unless string =~ BASE64_VALID_SEQUENCE
        raise InvalidDataURIError, "invalid base64 data"
      end
    end
    private_class_method :validate_base64_alphabet!

    ##
    # Strictly decodes a single base64 quad, including any terminal
    # padding.
    def self.decode_base64_quad(quad)
      c0 = BASE64_VALUES[quad.getbyte(0)]
      c1 = BASE64_VALUES[quad.getbyte(1)]
      b2 = quad.getbyte(2)
      b3 = quad.getbyte(3)
      if c0.nil? || c1.nil?
        raise InvalidDataURIError, "invalid base64 data"
      end
      if b2 == 0x3d
        unless b3 == 0x3d
          raise InvalidDataURIError, "invalid base64 padding"
        end
        return [c0 << 2 | c1 >> 4].pack("C")
      end
      c2 = BASE64_VALUES[b2]
      if c2.nil?
        raise InvalidDataURIError, "invalid base64 data"
      end
      if b3 == 0x3d
        n = (c0 << 18) | (c1 << 12) | (c2 << 6)
        return [(n >> 16) & 0xff, (n >> 8) & 0xff].pack("CC")
      end
      c3 = BASE64_VALUES[b3]
      if c3.nil?
        raise InvalidDataURIError, "invalid base64 data"
      end
      n = (c0 << 18) | (c1 << 12) | (c2 << 6) | c3
      [(n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff].pack("CCC")
    end
    private_class_method :decode_base64_quad

    ##
    # @return [String] The media type of the payload, without parameters.
    attr_reader :media_type

    ##
    # @return [Hash] The media type parameters, with lowercased names.
    attr_reader :params

    ##
    # Creates a data URI.
    #
    # @param [String] media_type
    #   The media type of the payload. Defaults to {DEFAULT_MEDIA_TYPE}.
    # @param [Hash] params
    #   Media type parameters, for example
    #   <code>{"charset" => "UTF-8"}</code>.
    # @param [String] data
    #   The decoded payload. Mutually exclusive with +:encoded_data+.
    # @param [String] encoded_data
    #   The payload in its wire encoding (percent- or base64-encoded,
    #   according to +:base64+). Mutually exclusive with +:data+.
    # @param [Boolean] base64
    #   Whether the payload is represented with base64 encoding.
    def initialize(media_type: DEFAULT_MEDIA_TYPE, params: {},
        data: nil, encoded_data: nil, base64: false)
      if data && encoded_data
        raise ArgumentError,
          ":data and :encoded_data are mutually exclusive"
      end
      unless media_type =~ MIME_MEDIA_TYPE
        raise InvalidDataURIError,
          "invalid media type: #{media_type.inspect}"
      end
      params.each_key do |name|
        unless name =~ MIME_TOKEN
          raise InvalidDataURIError,
            "invalid parameter name: #{name.inspect}"
        end
      end
      @media_type = media_type.downcase.freeze
      @params = params.each_with_object({}) do |(name, value), hash|
        hash[name.downcase] = value
      end.freeze
      @base64 = base64 ? true : false
      if encoded_data
        @encoded_data = encoded_data
      else
        @data = (data || "").b
      end
    end

    ##
    # @return [Boolean] Whether the payload uses base64 encoding.
    def base64?
      @base64
    end

    ##
    # @return [String, nil] The charset parameter, if present.
    def charset
      @params["charset"]
    end

    ##
    # @return [String] The decoded payload, as a binary String.
    def data
      if @data.nil?
        output = StringIO.new(String.new.b)
        decode_to(output)
        @data = output.string
      end
      @data
    end

    ##
    # Sets the payload from decoded data.
    #
    # @param [String] new_data The decoded payload.
    def data=(new_data)
      @data = new_data.b
      @encoded_data = nil
    end

    ##
    # @return [String] The payload in its wire encoding.
    def encoded_data
      if @encoded_data.nil?
        @encoded_data = if base64?
          [data].pack("m0")
        else
          self.class.percent_encode(data)
        end
      end
      @encoded_data
    end

    ##
    # Decodes this URI's payload incrementally, writing the decoded
    # bytes to +output+ as they become available.
    #
    # @param [#write] output The sink for the decoded bytes.
    # @param [Integer, nil] limit
    #   Maximum number of decoded bytes to accept. See {.decode_stream}.
    #
    # @return [Integer] The number of decoded bytes written.
    def decode_to(output, limit: nil)
      self.class.decode_stream(
        StringIO.new(encoded_data), output, :base64 => base64?, :limit => limit
      )
    end

    ##
    # Serializes the data URI.
    #
    # @param [Boolean, nil] base64
    #   Whether to serialize the payload with base64 encoding. When
    #   false, the payload is percent-encoded. Defaults to the
    #   encoding this URI was created with.
    #
    # @return [String] The serialized data URI.
    def to_s(base64: nil)
      base64 = base64? if base64.nil?
      payload =
        if base64 == base64?
          encoded_data
        elsif base64
          [data].pack("m0")
        else
          self.class.percent_encode(data)
        end
      uri = String.new("data:")
      uri << @media_type
      @params.each do |name, value|
        uri << ";" << name << "=" << value
      end
      uri << ";base64" if base64
      uri << "," << payload
      uri
    end

    ##
    # @return [String] The serialized data URI.
    def to_str
      to_s
    end

    ##
    # @return [String] A string representation of this data URI.
    def inspect
      format("#<%s:%#0x URI:%s>", self.class.to_s, self.object_id, to_s)
    end
  end
end
