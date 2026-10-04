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

module Addressable
  module IDNA
    ##
    # Punycode encoder/decoder as described in RFC 3492, extracted so that
    # both the legacy pure-Ruby IDNA implementation and the UTS #46
    # implementation can share it.
    module Punycode
      # Base class for Punycode errors.
      class Error < StandardError; end
      # Input is invalid.
      class BadInput < Error; end
      # Output would exceed the space provided.
      class BigOutput < Error; end
      # Input needs wider integers to process.
      class Overflow < Error; end

      UNICODE_MAX_LENGTH = 256
      ACE_MAX_LENGTH = 256

      BASE = 36
      TMIN = 1
      TMAX = 26
      SKEW = 38
      DAMP = 700
      INITIAL_BIAS = 72
      INITIAL_N = 0x80
      DELIMITER = 0x2D

      MAXINT = 1 << 64

      PRINT_ASCII =
        "\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n" +
        "\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n" +
        " !\"#$%&'()*+,-./" +
        "0123456789:;<=>?" +
        "@ABCDEFGHIJKLMNO" +
        "PQRSTUVWXYZ[\\]^_" +
        "`abcdefghijklmno" +
        "pqrstuvwxyz{|}~\n"

      ##
      # Encodes a Unicode string with Punycode.
      #
      # @param [String] unicode The Unicode string to encode.
      # @return [String] The Punycode-encoded string.
      def self.encode(unicode)
        unicode = unicode.to_s unless unicode.is_a?(String)
        input = unicode.unpack("U*")
        output = [0] * (ACE_MAX_LENGTH + 1)
        input_length = input.size
        max_out = ACE_MAX_LENGTH

        # Initialize the state
        n = INITIAL_N
        delta = out = 0
        bias = INITIAL_BIAS

        # Handle the basic code points:
        input_length.times do |j|
          if basic?(input[j])
            if max_out - out < 2
              raise BigOutput, "Output would exceed the space provided."
            end
            output[out] = input[j]
            out += 1
          end
        end

        h = b = out

        # h is the number of code points that have been handled, b is the
        # number of basic code points, and out is the number of characters
        # that have been output.

        if b > 0
          output[out] = DELIMITER
          out += 1
        end

        # Main encoding loop:

        while h < input_length
          # All non-basic code points < n have been
          # handled already.  Find the next larger one:

          m = MAXINT
          input_length.times do |j|
            m = input[j] if (n...m) === input[j]
          end

          # Increase delta enough to advance the decoder's
          # <n,i> state to <m,0>, but guard against overflow:

          if m - n > (MAXINT - delta) / (h + 1)
            raise Overflow, "Input needs wider integers to process."
          end
          delta += (m - n) * (h + 1)
          n = m

          input_length.times do |j|
            # Punycode does not need to check whether input[j] is basic:
            if input[j] < n
              delta += 1
              if delta == 0
                raise Overflow, "Input needs wider integers to process."
              end
            end

            if input[j] == n
              # Represent delta as a generalized variable-length integer:

              q = delta; k = BASE
              while true
                if out >= max_out
                  raise BigOutput, "Output would exceed the space provided."
                end
                t = (
                  if k <= bias
                    TMIN
                  elsif k >= bias + TMAX
                    TMAX
                  else
                    k - bias
                  end
                )
                break if q < t
                output[out] = encode_digit(t + (q - t) % (BASE - t))
                out += 1
                q = (q - t) / (BASE - t)
                k += BASE
              end

              output[out] = encode_digit(q)
              out += 1
              bias = adapt(delta, h + 1, h == b)
              delta = 0
              h += 1
            end
          end

          delta += 1
          n += 1
        end

        outlen = out
        outlen.times do |j|
          c = output[j]
          unless c >= 0 && c <= 127
            raise StandardError, "Invalid output char."
          end
          unless PRINT_ASCII[c]
            raise BadInput, "Input is invalid."
          end
        end

        output[0..outlen].map { |x| x.chr }.join("").sub(/\0+\z/, "")
      end

      ##
      # Decodes a Punycode string.
      #
      # @param [String] punycode The Punycode-encoded string.
      # @return [String] The decoded Unicode string.
      def self.decode(punycode)
        input = []
        output = []

        if ACE_MAX_LENGTH * 2 < punycode.size
          raise BigOutput, "Output would exceed the space provided."
        end
        punycode.each_byte do |c|
          unless c >= 0 && c <= 127
            raise BadInput, "Input is invalid."
          end
          input.push(c)
        end

        input_length = input.length
        max_out = UNICODE_MAX_LENGTH

        # Initialize the state
        n = INITIAL_N

        out = i = 0
        bias = INITIAL_BIAS

        # Handle the basic code points:  Let b be the number of input code
        # points before the last delimiter, or 0 if there is none, then
        # copy the first b code points to the output.

        b = 0
        input_length.times do |j|
          b = j if input[j] == DELIMITER
        end
        if b > max_out
          raise BigOutput, "Output would exceed the space provided."
        end

        b.times do |j|
          unless basic?(input[j])
            raise BadInput, "Input is invalid."
          end
          output[out] = input[j]
          out += 1
        end

        # Main decoding loop:  Start just after the last delimiter if any
        # basic code points were copied; start at the beginning otherwise.

        in_ = b > 0 ? b + 1 : 0
        while in_ < input_length

          # in_ is the index of the next character to be consumed, and
          # out is the number of code points in the output array.

          # Decode a generalized variable-length integer into delta,
          # which gets added to i.  The overflow checking is easier
          # if we increase i as we go, then subtract off its starting
          # value at the end to obtain delta.

          oldi = i; w = 1; k = BASE
          while true
            if in_ >= input_length
              raise BadInput, "Input is invalid."
            end
            digit = decode_digit(input[in_])
            in_ += 1
            if digit >= BASE
              raise BadInput, "Input is invalid."
            end
            if digit > (MAXINT - i) / w
              raise Overflow, "Input needs wider integers to process."
            end
            i += digit * w
            t = (
              if k <= bias
                TMIN
              elsif k >= bias + TMAX
                TMAX
              else
                k - bias
              end
            )
            break if digit < t
            if w > MAXINT / (BASE - t)
              raise Overflow, "Input needs wider integers to process."
            end
            w *= BASE - t
            k += BASE
          end

          bias = adapt(i - oldi, out + 1, oldi == 0)

          # I was supposed to wrap around from out + 1 to 0,
          # incrementing n each time, so we'll fix that now:

          if i / (out + 1) > MAXINT - n
            raise Overflow, "Input needs wider integers to process."
          end
          n += i / (out + 1)
          i %= out + 1

          # Insert n at position i of the output:

          if out >= max_out
            raise BigOutput, "Output would exceed the space provided."
          end

          output[i + 1, out - i] = output[i, out - i]
          output[i] = n
          i += 1

          out += 1
        end

        output.pack("U*")
      end

      def self.basic?(codepoint)
        codepoint < 0x80
      end
      private_class_method :basic?

      def self.encode_digit(d)
        d + 22 + 75 * ((d < 26) ? 1 : 0)
      end
      private_class_method :encode_digit

      # Returns the numeric value of a basic codepoint
      # (for use in representing integers) in the range 0 to
      # base - 1, or BASE if codepoint does not represent a value.
      def self.decode_digit(codepoint)
        if codepoint - 48 < 10
          codepoint - 22
        elsif codepoint - 65 < 26
          codepoint - 65
        elsif codepoint - 97 < 26
          codepoint - 97
        else
          BASE
        end
      end
      private_class_method :decode_digit

      # Bias adaptation method
      def self.adapt(delta, numpoints, firsttime)
        delta = firsttime ? delta / DAMP : delta >> 1
        # delta >> 1 is a faster way of doing delta / 2
        delta += delta / numpoints
        difference = BASE - TMIN

        k = 0
        while delta > (difference * TMAX) / 2
          delta /= difference
          k += BASE
        end

        k + (difference + 1) * delta / (delta + SKEW)
      end
      private_class_method :adapt
    end
  end
end
