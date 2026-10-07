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


require "addressable/idna/uts46_data"

module Addressable
  module IDNA
    ##
    # Pure-Ruby implementation of UTS #46 (Unicode IDNA Compatibility
    # Processing), pinned to the Unicode #{UTS46::UNICODE_VERSION} data
    # shipped in uts46_data.rb.  The data is bundled with the gem: nothing
    # is downloaded at runtime and no native libidn is required.
    #
    # Supports transitional and nontransitional processing, STD3 ASCII
    # rules, and label length, Bidi (RFC 5893) and ContextJ (RFC 5892)
    # checks.  Conversion errors identify the offending label and rule.
    module UTS46
      ACE_PREFIX = "xn--"
      MAX_LABEL_LENGTH = 63
      MAX_DOMAIN_LENGTH = 253

      # Label separators: U+002E plus the dot-like characters that the
      # mapping table folds to U+002E.
      DOT_REGEX = /[.\u{3002}\u{FF0E}\u{FF61}]/

      ##
      # Raised when UTS 46 processing fails.
      #
      # Carries the offending +label+, the +rule+ that was violated (for
      # example +:disallowed+, +:std3+, +:hyphen+, +:contextj+, +:bidi+,
      # +:label_length+ or +:domain_length+) and, when relevant, the
      # +codepoint+ that triggered the failure.
      class Error < StandardError
        attr_reader :label, :rule, :codepoint

        def initialize(rule, label: nil, codepoint: nil)
          @rule = rule
          @label = label
          @codepoint = codepoint
          super(Error.build_message(rule, label, codepoint))
        end

        def self.build_message(rule, label, codepoint)
          message = "UTS 46 #{rule} check failed"
          message += " for label #{label.inspect}" if label
          message += format(" (offending code point U+%04X)", codepoint) if codepoint
          message
        end
      end

      # Raised for malformed punycode; wrapped in UTS46::Error publicly.
      class PunycodeError < StandardError; end

      class << self
        ##
        # Converts a Unicode internationalized domain name to its ASCII
        # (A-label) form using UTS 46 processing.
        #
        # @param [String] domain The domain name to convert.
        # @param [Boolean] transitional Use transitional processing
        #   (maps deviation characters: ß→ss, ς→σ, ZWNJ/ZWJ removed).
        # @param [Boolean] use_std3_rules Apply STD3 ASCII rules.
        # @param [Boolean] check_bidi Apply the RFC 5893 Bidi Rule.
        # @param [Boolean] check_joiners Apply ContextJ joiner checks.
        # @param [Boolean] check_hyphens Check hyphen placement.
        # @param [Boolean] verify_dns_length Enforce DNS length limits.
        #
        # @return [String] The ASCII form of the domain.
        # @raise [UTS46::Error] when processing fails.
        def to_ascii(domain, transitional: false, use_std3_rules: true,
            check_bidi: true, check_joiners: true, check_hyphens: true,
            verify_dns_length: true)
          options = {
            use_std3_rules: use_std3_rules,
            check_bidi: check_bidi,
            check_joiners: check_joiners,
            check_hyphens: check_hyphens
          }
          labels = mapped_labels(domain, transitional, use_std3_rules)
          ascii_labels = labels.each_with_index.map do |label, index|
            if label.empty?
              unless index == labels.length - 1
                raise Error.new(:empty_label, label: domain.to_s)
              end
              ""
            else
              label_to_ascii(label, options)
            end
          end
          result = ascii_labels.join(".")
          if verify_dns_length
            ascii_labels.each_with_index do |label, index|
              next if label.empty? && index == ascii_labels.length - 1
              if label.empty? || label.length > MAX_LABEL_LENGTH
                raise Error.new(:label_length, label: label)
              end
            end
            total = result.end_with?(".") ? result.length - 1 : result.length
            if total > MAX_DOMAIN_LENGTH
              raise Error.new(:domain_length, label: result)
            end
          end
          result
        end

        ##
        # Converts an ASCII domain name to its Unicode (U-label) form.
        # Mirrors UTS 46 ToUnicode: it never fails; labels that cannot be
        # decoded are left unchanged.
        #
        # @param [String] domain The domain name to convert.
        # @return [String] The Unicode form of the domain.
        def to_unicode(domain, **_options)
          input = domain.is_a?(String) ? domain.dup : domain.to_s
          input.force_encoding(Encoding::UTF_8)
          return domain.to_s unless input.valid_encoding?
          labels = input.split(DOT_REGEX, -1).map do |label|
            mapped = map_label(label, false, false, lenient: true)
            mapped = mapped.unicode_normalize(:nfc)
            if mapped.downcase.start_with?(ACE_PREFIX)
              begin
                punycode_decode(mapped[ACE_PREFIX.length..])
              rescue PunycodeError
                mapped
              end
            else
              mapped
            end
          end
          labels.join(".")
        end

        private

        def mapped_labels(domain, transitional, use_std3_rules)
          input = domain.is_a?(String) ? domain.dup : domain.to_s
          input.force_encoding(Encoding::UTF_8)
          unless input.valid_encoding?
            raise Error.new(:invalid_input, label: domain.to_s)
          end
          input.split(DOT_REGEX, -1).map do |label|
            map_label(label, transitional, use_std3_rules).unicode_normalize(:nfc)
          end
        end

        def map_label(label, transitional, use_std3_rules, lenient: false)
          output = []
          label.unpack("U*").each do |cp|
            case status_of(cp)
            when STATUS_VALID
              output << cp
            when STATUS_IGNORED
              next
            when STATUS_MAPPED
              output.concat(MAPPINGS[cp].unpack("U*"))
            when STATUS_DEVIATION
              if transitional
                output.concat(MAPPINGS[cp].unpack("U*"))
              else
                output << cp
              end
            when STATUS_DISALLOWED_STD3_VALID
              if use_std3_rules
                raise Error.new(:std3, label: label, codepoint: cp)
              end
              output << cp
            when STATUS_DISALLOWED_STD3_MAPPED
              if use_std3_rules
                raise Error.new(:std3, label: label, codepoint: cp)
              end
              output.concat(MAPPINGS[cp].unpack("U*"))
            else
              if lenient
                output << cp
                next
              end
              raise Error.new(:disallowed, label: label, codepoint: cp)
            end
          end
          output.pack("U*")
        end

        def label_to_ascii(label, options)
          if label.start_with?(ACE_PREFIX)
            return validate_ace_label(label, options)
          end
          check_hyphens(label) if options[:check_hyphens]
          validate_label(label, options)
          if label.ascii_only?
            label
          else
            ACE_PREFIX + punycode_encode(label)
          end
        end

        def validate_ace_label(label, options)
          begin
            decoded = punycode_decode(label[ACE_PREFIX.length..])
          rescue PunycodeError
            raise Error.new(:punycode, label: label)
          end
          if decoded.empty? || decoded.ascii_only? ||
              decoded.unicode_normalize(:nfc) != decoded
            raise Error.new(:invalid_ace_label, label: label)
          end
          validate_label(decoded, options)
          unless ACE_PREFIX + punycode_encode(decoded) == label
            raise Error.new(:invalid_ace_label, label: label)
          end
          label
        end

        def validate_label(label, options)
          cps = label.unpack("U*")
          if mark?(cps.first)
            raise Error.new(:leading_combining_mark, label: label, codepoint: cps.first)
          end
          cps.each do |cp|
            status = status_of(cp)
            next if status == STATUS_VALID || status == STATUS_DEVIATION
            next if status == STATUS_DISALLOWED_STD3_VALID && !options[:use_std3_rules]
            raise Error.new(:disallowed, label: label, codepoint: cp)
          end
          check_contextj(label, cps) if options[:check_joiners]
          check_bidi(label, cps) if options[:check_bidi]
        end

        def check_hyphens(label)
          if label.start_with?("-") || label.end_with?("-")
            raise Error.new(:hyphen, label: label)
          end
          if label.length >= 4 && label[2] == "-" && label[3] == "-"
            raise Error.new(:hyphen, label: label)
          end
        end

        # RFC 5892 Appendix A contextual rules for ZWNJ and ZWJ.
        def check_contextj(label, cps)
          cps.each_with_index do |cp, index|
            if cp == 0x200C
              valid = (index > 0 && virama?(cps[index - 1])) ||
                contextj_joining_ok?(cps, index)
              unless valid
                raise Error.new(:contextj, label: label, codepoint: cp)
              end
            elsif cp == 0x200D
              unless index > 0 && virama?(cps[index - 1])
                raise Error.new(:contextj, label: label, codepoint: cp)
              end
            end
          end
        end

        def contextj_joining_ok?(cps, index)
          before = index - 1
          before -= 1 while before >= 0 && joining_of(cps[before]) == JOINING_T
          return false if before < 0
          unless [JOINING_L, JOINING_D].include?(joining_of(cps[before]))
            return false
          end
          after = index + 1
          after += 1 while after < cps.length && joining_of(cps[after]) == JOINING_T
          return false if after >= cps.length
          [JOINING_R, JOINING_D].include?(joining_of(cps[after]))
        end

        # The Bidi Rule, RFC 5893 section 2.
        def check_bidi(label, cps)
          classes = cps.map { |cp| bidi_class_of(cp) }
          # The Bidi Rule applies only to labels containing R, AL or AN.
          return unless classes.any? { |klass| [:R, :AL, :AN].include?(klass) }
          first = classes.first
          unless [:L, :R, :AL].include?(first)
            raise Error.new(:bidi, label: label, codepoint: cps.first)
          end
          last = classes.reverse.find { |klass| klass != :NSM }
          if first == :L
            if classes.any? { |klass| [:R, :AL, :AN].include?(klass) }
              raise Error.new(:bidi, label: label)
            end
            unless last == :L || last == :EN
              raise Error.new(:bidi, label: label)
            end
          else
            if classes.any? { |klass| klass == :L }
              raise Error.new(:bidi, label: label)
            end
            if classes.include?(:EN) && classes.include?(:AN)
              raise Error.new(:bidi, label: label)
            end
            unless [:R, :AL, :EN, :AN].include?(last)
              raise Error.new(:bidi, label: label)
            end
          end
        end

        def status_of(cp)
          STATUS_RANGES[bsearch(STATUS_RANGES, cp)][2]
        end

        def bidi_class_of(cp)
          index = bsearch(BIDI_RANGES, cp)
          index ? BIDI_CLASSES[BIDI_RANGES[index][2]] : :L
        end

        def joining_of(cp)
          index = bsearch(JOINING_RANGES, cp)
          index ? JOINING_RANGES[index][2] : nil
        end

        def mark?(cp)
          !bsearch(MARK_RANGES, cp).nil?
        end

        def virama?(cp)
          !VIRAMA.bsearch { |v| cp <=> v }.nil?
        end

        def bsearch(ranges, cp)
          ranges.bsearch_index { |range| cp < range[0] ? -1 : (cp <= range[1] ? 0 : 1) }
        end

        # Punycode (RFC 3492) encoder/decoder, self-contained so that the
        # UTS 46 mode never depends on a native libidn.
        PUNYCODE_BASE = 36
        PUNYCODE_TMIN = 1
        PUNYCODE_TMAX = 26
        PUNYCODE_SKEW = 38
        PUNYCODE_DAMP = 700
        PUNYCODE_INITIAL_BIAS = 72
        PUNYCODE_INITIAL_N = 0x80
        PUNYCODE_DELIMITER = 0x2D
        PUNYCODE_MAXINT = 1 << 64
        PUNYCODE_MAX_OUTPUT = 1024

        def punycode_encode(unicode)
          input = unicode.unpack("U*")
          output = +""

          input.each do |cp|
            output << cp.chr if cp < 0x80
          end
          h = b = output.length
          output << "-" if b > 0

          n = PUNYCODE_INITIAL_N
          delta = 0
          bias = PUNYCODE_INITIAL_BIAS

          while h < input.length
            m = PUNYCODE_MAXINT
            input.each do |cp|
              m = cp if cp >= n && cp < m
            end
            if m - n > (PUNYCODE_MAXINT - delta) / (h + 1)
              raise PunycodeError, "Input needs wider integers to process."
            end
            delta += (m - n) * (h + 1)
            n = m

            input.each do |cp|
              if cp < n
                delta += 1
                if delta == 0
                  raise PunycodeError, "Input needs wider integers to process."
                end
              end
              next unless cp == n
              q = delta
              k = PUNYCODE_BASE
              loop do
                if output.length >= PUNYCODE_MAX_OUTPUT
                  raise PunycodeError, "Output would exceed the space provided."
                end
                t =
                  if k <= bias
                    PUNYCODE_TMIN
                  elsif k >= bias + PUNYCODE_TMAX
                    PUNYCODE_TMAX
                  else
                    k - bias
                  end
                break if q < t
                output << punycode_encode_digit(t + (q - t) % (PUNYCODE_BASE - t))
                q = (q - t) / (PUNYCODE_BASE - t)
                k += PUNYCODE_BASE
              end
              output << punycode_encode_digit(q)
              bias = punycode_adapt(delta, h + 1, h == b)
              delta = 0
              h += 1
            end
            delta += 1
            n += 1
          end
          output
        end

        def punycode_decode(punycode)
          input = punycode.bytes
          if input.any? { |byte| byte > 0x7F }
            raise PunycodeError, "Input is invalid."
          end

          output = []
          n = PUNYCODE_INITIAL_N
          i = 0
          bias = PUNYCODE_INITIAL_BIAS

          b = 0
          input.each_with_index { |byte, index| b = index if byte == PUNYCODE_DELIMITER }
          if b > PUNYCODE_MAX_OUTPUT
            raise PunycodeError, "Output would exceed the space provided."
          end
          b.times do |j|
            if input[j] >= 0x80
              raise PunycodeError, "Input is invalid."
            end
            output << input[j]
          end

          position = b > 0 ? b + 1 : 0
          while position < input.length
            oldi = i
            w = 1
            k = PUNYCODE_BASE
            loop do
              if position >= input.length
                raise PunycodeError, "Input is invalid."
              end
              digit = punycode_decode_digit(input[position])
              position += 1
              if digit >= PUNYCODE_BASE
                raise PunycodeError, "Input is invalid."
              end
              if digit > (PUNYCODE_MAXINT - i) / w
                raise PunycodeError, "Input needs wider integers to process."
              end
              i += digit * w
              t =
                if k <= bias
                  PUNYCODE_TMIN
                elsif k >= bias + PUNYCODE_TMAX
                  PUNYCODE_TMAX
                else
                  k - bias
                end
              break if digit < t
              if w > PUNYCODE_MAXINT / (PUNYCODE_BASE - t)
                raise PunycodeError, "Input needs wider integers to process."
              end
              w *= PUNYCODE_BASE - t
              k += PUNYCODE_BASE
            end

            bias = punycode_adapt(i - oldi, output.length + 1, oldi == 0)
            if i / (output.length + 1) > PUNYCODE_MAXINT - n
              raise PunycodeError, "Input needs wider integers to process."
            end
            n += i / (output.length + 1)
            i %= output.length + 1

            if output.length >= PUNYCODE_MAX_OUTPUT
              raise PunycodeError, "Output would exceed the space provided."
            end
            output.insert(i, n)
            i += 1
          end
          output.pack("U*")
        end

        def punycode_encode_digit(digit)
          (digit + 22 + 75 * (digit < 26 ? 1 : 0)).chr
        end

        def punycode_decode_digit(codepoint)
          if codepoint - 48 < 10
            codepoint - 22
          elsif codepoint - 65 < 26
            codepoint - 65
          elsif codepoint - 97 < 26
            codepoint - 97
          else
            PUNYCODE_BASE
          end
        end

        def punycode_adapt(delta, numpoints, firsttime)
          delta = firsttime ? delta / PUNYCODE_DAMP : delta >> 1
          delta += delta / numpoints
          difference = PUNYCODE_BASE - PUNYCODE_TMIN
          k = 0
          while delta > (difference * PUNYCODE_TMAX) / 2
            delta /= difference
            k += PUNYCODE_BASE
          end
          k + (difference + 1) * delta / (delta + PUNYCODE_SKEW)
        end
      end
    end
  end
end
