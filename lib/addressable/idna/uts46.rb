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

require "addressable/idna/punycode"
require "addressable/idna/uts46_data"

module Addressable
  module IDNA
    ##
    # UTS #46 (Unicode IDNA Compatibility Processing) implemented in pure
    # Ruby against a pinned Unicode data version (see {UNICODE_VERSION}).
    #
    # The whole pipeline is wired together here: mapping, NFC
    # normalization, the ContextJ/ContextO contextual rules, the Bidi
    # rule, hyphen and STD3 ASCII checks, and DNS length verification.
    # All rule tables ship inside the gem (see
    # lib/addressable/idna/uts46_data.rb); nothing is downloaded at
    # runtime.
    #
    # Processing is driven by an immutable {Config} object. Two
    # ready-made, independent configurations are provided:
    #
    # * {UTS46::TRANSITIONAL} - transitional processing (maps deviation
    #   characters such as U+00DF LATIN SMALL LETTER SHARP S to "ss").
    # * {UTS46::NONTRANSITIONAL} - nontransitional processing (keeps
    #   deviation characters as they are).
    #
    # Both ToASCII and ToUnicode report which labels failed and why:
    # they return a {Result} whose +errors+ are {LabelError} objects
    # carrying the offending label, its index in the domain name, and
    # the UTS #46 / IDNA2008 status codes that were triggered. A label
    # is never considered valid merely because it happens to decode as
    # Punycode; ACE labels are decoded, fully validated, and verified
    # by re-encoding before they are accepted.
    #
    # @example
    #   Addressable::IDNA::UTS46.to_ascii("faß.de").output
    #   # => "xn--fa-hia.de"
    #   Addressable::IDNA::UTS46.to_ascii(
    #     "faß.de", config: Addressable::IDNA::UTS46::TRANSITIONAL
    #   ).output
    #   # => "fass.de"
    module UTS46
      ACE_PREFIX = "xn--"
      MAX_LABEL_LENGTH = 63
      MAX_DOMAIN_LENGTH = 253

      # Code points treated as label separators in addition to ".":
      # U+3002 IDEOGRAPHIC FULL STOP, U+FF0E FULLWIDTH FULL STOP and
      # U+FF61 HALFWIDTH FULL STOP all map to "." in the mapping table.
      DOT_SEPARATOR = /[.\u{3002}\u{FF0E}\u{FF61}]/

      # Error code used when the input cannot be treated as UTF-8.
      INVALID_ENCODING = "E1"

      ##
      # Immutable UTS #46 processing configuration. All flags correspond
      # to the input flags defined by UTS #46 section 4.
      class Config
        # @return [Boolean] Transitional_Processing: map deviation
        #   characters instead of keeping them.
        attr_reader :transitional
        # @return [Boolean] UseSTD3ASCIIRules: reject ASCII characters
        #   outside the LDH set.
        attr_reader :use_std3_ascii_rules
        # @return [Boolean] CheckBidi: apply the IDNA2008 Bidi rule.
        attr_reader :check_bidi
        # @return [Boolean] CheckHyphens: apply the hyphen restrictions.
        attr_reader :check_hyphens
        # @return [Boolean] CheckJoiners: apply the ContextJ rules.
        attr_reader :check_joiners
        # @return [Boolean] VerifyDnsLength: enforce DNS length limits.
        attr_reader :verify_dns_length

        def initialize(
          transitional: false,
          use_std3_ascii_rules: false,
          check_bidi: true,
          check_hyphens: true,
          check_joiners: true,
          verify_dns_length: true
        )
          @transitional = transitional ? true : false
          @use_std3_ascii_rules = use_std3_ascii_rules ? true : false
          @check_bidi = check_bidi ? true : false
          @check_hyphens = check_hyphens ? true : false
          @check_joiners = check_joiners ? true : false
          @verify_dns_length = verify_dns_length ? true : false
          freeze
        end

        def transitional?
          @transitional
        end

        def use_std3_ascii_rules?
          @use_std3_ascii_rules
        end

        def check_bidi?
          @check_bidi
        end

        def check_hyphens?
          @check_hyphens
        end

        def check_joiners?
          @check_joiners
        end

        def verify_dns_length?
          @verify_dns_length
        end

        def ==(other)
          other.is_a?(Config) &&
            transitional == other.transitional &&
            use_std3_ascii_rules == other.use_std3_ascii_rules &&
            check_bidi == other.check_bidi &&
            check_hyphens == other.check_hyphens &&
            check_joiners == other.check_joiners &&
            verify_dns_length == other.verify_dns_length
        end
        alias_method :eql?, :==

        def hash
          [
            self.class, @transitional, @use_std3_ascii_rules,
            @check_bidi, @check_hyphens, @check_joiners, @verify_dns_length
          ].hash
        end
      end

      # Transitional processing configuration. Frozen and therefore
      # safe to share; it cannot influence, or be influenced by, any
      # other configuration object.
      TRANSITIONAL = Config.new(transitional: true).freeze

      # Nontransitional processing configuration (the UTS #46 default).
      NONTRANSITIONAL = Config.new.freeze

      ##
      # Describes the errors found in a single label of a domain name.
      class LabelError
        # @return [String] The offending label, as it appeared in the
        #   input domain name.
        attr_reader :label
        # @return [Integer] Zero-based index of the label in the domain
        #   name.
        attr_reader :index
        # @return [Array<String>] UTS #46 / IDNA2008 status codes
        #   triggered by this label (for example "V6", "B1", "C1",
        #   "A4_2").
        attr_reader :codes

        def initialize(label:, index:, codes:)
          @label = label
          @index = index
          @codes = codes.uniq.freeze
          freeze
        end

        def ==(other)
          other.is_a?(LabelError) &&
            label == other.label &&
            index == other.index &&
            codes == other.codes
        end
        alias_method :eql?, :==

        def hash
          [self.class, @label, @index, @codes].hash
        end

        def to_s
          "#{label.inspect} (label #{index}): #{codes.join(' ')}"
        end
      end

      ##
      # The outcome of a ToASCII or ToUnicode operation: the processed
      # domain name plus, for every label that failed one or more
      # checks, a {LabelError} describing what went wrong.
      class Result
        # @return [String] The processed domain name.
        attr_reader :output
        # @return [Array<LabelError>] Per-label error information, in
        #   label order.
        attr_reader :errors

        def initialize(output:, errors:)
          @output = output
          @errors = errors.freeze
          freeze
        end

        # @return [Boolean] +true+ if no label reported any error.
        def success?
          @errors.empty?
        end

        def ==(other)
          other.is_a?(Result) &&
            output == other.output &&
            errors == other.errors
        end
        alias_method :eql?, :==

        def hash
          [self.class, @output, @errors].hash
        end
      end

      ##
      # Raised by the bang variants ({UTS46.to_ascii!},
      # {UTS46.to_unicode!}) when a domain name fails UTS #46
      # processing. Carries the same per-label {LabelError} information
      # as {Result}.
      class InvalidDomainError < StandardError
        # @return [Array<LabelError>]
        attr_reader :errors

        def initialize(errors)
          @errors = errors
          super(
            "Invalid domain name: " +
              errors.map(&:to_s).join(", ")
          )
        end
      end

      class << self
        ##
        # Converts a Unicode domain name to its ASCII (ACE) form using
        # UTS #46 processing.
        #
        # @param [String, #to_str] domain The domain name to convert.
        # @param [Config] config The processing configuration.
        # @return [Result] The processed domain name and, for every
        #   label that failed a check, a {LabelError}. The operation
        #   itself never raises for malformed domain names; inspect
        #   {Result#success?} or use {to_ascii!} instead.
        def to_ascii(domain, config: NONTRANSITIONAL)
          process(domain, config, true)
        end

        ##
        # Like {to_ascii}, but returns the ASCII domain name directly
        # and raises {InvalidDomainError} if any label fails.
        #
        # @param [String, #to_str] domain The domain name to convert.
        # @param [Config] config The processing configuration.
        # @return [String] The ASCII form of the domain name.
        def to_ascii!(domain, config: NONTRANSITIONAL)
          result = to_ascii(domain, config: config)
          raise InvalidDomainError, result.errors unless result.success?
          result.output
        end

        ##
        # Converts an ASCII (ACE) domain name to its Unicode form using
        # UTS #46 processing. As defined by UTS #46, this operation
        # never fails: errors are recorded per label, but an output
        # string is always produced. A label is never accepted merely
        # because it decodes as Punycode; ACE labels are validated and
        # verified by re-encoding.
        #
        # @param [String, #to_str] domain The domain name to convert.
        # @param [Config] config The processing configuration.
        # @return [Result] The processed domain name and per-label
        #   error information.
        def to_unicode(domain, config: NONTRANSITIONAL)
          process(domain, config, false)
        end

        ##
        # Like {to_unicode}, but returns the Unicode domain name
        # directly. Still never raises for malformed domain names.
        #
        # @param [String, #to_str] domain The domain name to convert.
        # @param [Config] config The processing configuration.
        # @return [String] The Unicode form of the domain name.
        def to_unicode!(domain, config: NONTRANSITIONAL)
          to_unicode(domain, config: config).output
        end

        private

        def process(domain, config, to_ascii)
          input = domain.to_s unless domain.is_a?(String)
          input ||= domain
          input = input.dup.force_encoding(Encoding::UTF_8)
          unless input.valid_encoding?
            return Result.new(
              output: input,
              errors: [LabelError.new(
                label: input, index: 0, codes: [INVALID_ENCODING]
              )]
            )
          end

          labels = input.split(DOT_SEPARATOR, -1)
          labels = [""] if labels.empty?

          processed = labels.each_with_index.map do |label, index|
            process_label(label, index, config, to_ascii)
          end

          # A single trailing empty label is the DNS root and is kept
          # out of the per-label checks. Whether the last label is
          # empty can only be told after mapping, since ignored code
          # points (and deviations in transitional processing) may
          # empty a label out.
          root = processed.length > 1 && processed.last[:mapped].empty?
          processed.pop if root

          if config.check_bidi? && processed.any? { |info| rtl_label?(info[:cps]) }
            processed.each { |info| check_label_bidi(info) }
          end

          if config.verify_dns_length?
            processed.each do |info|
              if info[:output].empty?
                info[:codes] << (to_ascii ? "A4_2" : "X4_2")
              elsif to_ascii && info[:output].bytesize > MAX_LABEL_LENGTH
                info[:codes] << "A4_2"
              end
            end
          end

          output = processed.map { |info| info[:output] }.join(".")
          output += "." if root

          if to_ascii && config.transitional? && !root &&
             processed.all? { |info| info[:mapped].empty? }
            # A domain name that maps to nothing in transitional
            # processing keeps the nontransitional ToASCII output
            # (its own errors, e.g. the empty-label A4_2, still apply).
            output = process(input, nontransitional(config), true).output
          end

          if to_ascii && config.verify_dns_length?
            effective_length = output.length - (root ? 1 : 0)
            if effective_length > MAX_DOMAIN_LENGTH
              processed.last[:codes] << "A4_1"
            end
          end

          errors = processed.each_with_object([]) do |info, list|
            next if info[:codes].empty?
            list << LabelError.new(
              label: info[:label], index: info[:index], codes: info[:codes]
            )
          end

          Result.new(output: output, errors: errors)
        end

        def process_label(label, index, config, to_ascii)
          codes = []
          mapped = map_label(label, config, codes)
          normalized = nfc(mapped)

          info =
            if ace_label?(normalized)
              process_ace_label(
                label, index, normalized, config, to_ascii, codes
              )
            else
              validate_label(normalized, config, codes)
              output =
                if to_ascii
                  encode_label(normalized)
                else
                  normalized
                end
              {
                label: label, index: index, codes: codes,
                output: output, cps: normalized.codepoints
              }
            end
          info[:mapped] = normalized
          info
        end

        # Maps every code point of a label according to the UTS #46
        # mapping table, recording disallowed code points as V6 errors.
        def map_label(label, config, codes)
          output = +""
          label.each_char do |char|
            map_char(char, config, codes, output)
          end
          output
        end

        # Mapping results are themselves subject to mapping: U+1E9E
        # LATIN CAPITAL LETTER SHARP S maps to U+00DF, which in
        # transitional processing maps on to "ss".
        def map_char(char, config, codes, output)
          status, mapping = lookup_mapping(char)
          case status
          when STATUS_VALID
            output << char
          when STATUS_IGNORED
            # dropped
          when STATUS_MAPPED
            map_label_into(mapping, config, codes, output)
          when STATUS_DEVIATION
            if config.transitional?
              map_label_into(mapping, config, codes, output)
            else
              output << char
            end
          when STATUS_DISALLOWED
            codes << "V6"
            output << char
          when STATUS_DISALLOWED_STD3_VALID
            # Kept at mapping time; the STD3 check happens as a
            # validity check after normalization (UTS #46 section
            # 4.1, criterion 6).
            output << char
          when STATUS_DISALLOWED_STD3_MAPPED
            if config.use_std3_ascii_rules?
              output << char
            else
              map_label_into(mapping, config, codes, output)
            end
          end
        end

        def map_label_into(mapping, config, codes, output)
          mapping.each_char do |char|
            map_char(char, config, codes, output)
          end
        end

        def ace_label?(label)
          label.length >= 4 && label[0, 4] == ACE_PREFIX
        end

        def process_ace_label(label, index, normalized, config, to_ascii, codes)
          puny_part = normalized[4..]
          decoded = nil
          if puny_part.ascii_only?
            begin
              decoded = Punycode.decode(puny_part)
            rescue Punycode::Error
              decoded = nil
            end
          end

          if decoded.nil?
            # Not a valid ACE label: record the error and treat the
            # label as an ordinary one for output purposes.
            codes << "P4"
            output = to_ascii ? encode_label(normalized) : normalized
            return {
              label: label, index: index, codes: codes,
              output: output, cps: normalized.codepoints
            }
          end

          decoded_cps = decoded.codepoints
          validate_decoded_label(decoded_cps, config, codes)

          if codes.empty?
            # Round-trip verification: a valid ACE label must be the
            # canonical nontransitional ToASCII form of its decoding.
            reencoded = ascii_form(decoded_cps, config)
            unless reencoded && reencoded.casecmp(normalized).zero?
              codes << "P4"
            end
          end

          output = to_ascii ? normalized : decoded
          {
            label: label, index: index, codes: codes,
            output: output, cps: decoded_cps
          }
        end

        # The canonical ASCII form of a decoded label, used for ACE
        # round-trip verification. Always nontransitional, per UTS #46.
        def ascii_form(decoded_cps, config)
          map_codes = []
          mapped = map_label(
            decoded_cps.pack("U*"), nontransitional(config), map_codes
          )
          return nil unless map_codes.empty?
          encode_label(nfc(mapped))
        end

        # The same configuration with Transitional_Processing off.
        def nontransitional(config)
          return NONTRANSITIONAL unless config.transitional?
          Config.new(
            transitional: false,
            use_std3_ascii_rules: config.use_std3_ascii_rules?,
            check_bidi: config.check_bidi?,
            check_hyphens: config.check_hyphens?,
            check_joiners: config.check_joiners?,
            verify_dns_length: config.verify_dns_length?
          )
        end

        # Encodes a validated label for ToASCII: ASCII labels pass
        # through, labels containing non-ASCII code points become ACE.
        def encode_label(label)
          if label.ascii_only?
            label
          else
            ACE_PREFIX + Punycode.encode(label)
          end
        end

        # Validity checks for a mapped and normalized label.
        def validate_label(label, config, codes)
          cps = label.codepoints
          check_status_values(cps, config, codes)
          check_hyphens(cps, config, codes)
          check_leading_mark(cps, codes)
          check_contextj(cps, config, codes)
          check_contexto(cps, codes)
        end

        # UTS #46 section 4.1, criterion 6: every code point in the
        # normalized label must have an allowed mapping status; with
        # UseSTD3ASCIIRules, STD3-disallowed ASCII code points are
        # rejected here (after normalization, so characters composed
        # away by NFC are not flagged).
        def check_status_values(cps, config, codes)
          cps.each do |cp|
            codes << "V6" unless valid_in_label?(cp, config)
          end
        end

        # Validity checks for a label decoded from an ACE label.
        def validate_decoded_label(cps, config, codes)
          codes << "V1" unless nfc(cps.pack("U*")) == cps.pack("U*")
          check_status_values(cps, config, codes)
          check_hyphens(cps, config, codes)
          check_leading_mark(cps, codes)
          check_contextj(cps, config, codes)
          check_contexto(cps, codes)
        end

        # A code point is allowed in a validated label when its mapping
        # status is valid or deviation (or disallowed_STD3_valid with
        # STD3 rules off); anything else is a V6 error.
        def valid_in_label?(cp, config)
          status, = lookup_mapping_cp(cp)
          case status
          when STATUS_VALID, STATUS_DEVIATION
            true
          when STATUS_DISALLOWED_STD3_VALID
            !config.use_std3_ascii_rules?
          else
            false
          end
        end

        # Plain disallowed code points are also reported at mapping
        # time (UTS #46 section 4, step 1); this check simply avoids
        # recording the same code twice at validity time.

        def check_hyphens(cps, config, codes)
          return unless config.check_hyphens?
          codes << "V2" if cps.length >= 4 && cps[2] == 0x2D && cps[3] == 0x2D
          codes << "V3" if !cps.empty? && (cps.first == 0x2D || cps.last == 0x2D)
        end

        def check_leading_mark(cps, codes)
          return if cps.empty?
          codes << "V5" if mark?(cps.first)
        end

        # RFC 5892 Appendix A.1 (ZERO WIDTH NON-JOINER) and A.2
        # (ZERO WIDTH JOINER).
        def check_contextj(cps, config, codes)
          return unless config.check_joiners?
          cps.each_with_index do |cp, i|
            if cp == 0x200C
              ok = i > 0 && ccc(cps[i - 1]) == 9
              unless ok
                j = i - 1
                j -= 1 while j >= 0 && joining_type(cps[j]) == JT_TRANSPARENT
                pre =
                  j >= 0 && [JT_LEFT, JT_DUAL].include?(joining_type(cps[j]))
                k = i + 1
                k += 1 while k < cps.length &&
                  joining_type(cps[k]) == JT_TRANSPARENT
                post =
                  k < cps.length &&
                  [JT_RIGHT, JT_DUAL].include?(joining_type(cps[k]))
                ok = pre && post
              end
              codes << "C1" unless ok
            elsif cp == 0x200D
              codes << "C2" unless i > 0 && ccc(cps[i - 1]) == 9
            end
          end
        end

        # RFC 5892 Appendix A.3-A.8 (CONTEXTO rules).
        def check_contexto(cps, codes)
          cps.each_with_index do |cp, i|
            case cp
            when 0x00B7
              # MIDDLE DOT: must be surrounded by "l" (U+006C).
              unless i > 0 && cps[i - 1] == 0x6C &&
                     i < cps.length - 1 && cps[i + 1] == 0x6C
                codes << "C3"
              end
            when 0x0375
              # GREEK LOWER NUMERAL SIGN: next char must be Greek.
              unless i < cps.length - 1 &&
                     script(cps[i + 1]) == SCRIPT_GREEK
                codes << "C4"
              end
            when 0x05F3
              # HEBREW PUNCTUATION GERESH: previous char must be Hebrew.
              unless i > 0 && script(cps[i - 1]) == SCRIPT_HEBREW
                codes << "C5"
              end
            when 0x05F4
              # HEBREW PUNCTUATION GERSHAYIM: previous char must be Hebrew.
              unless i > 0 && script(cps[i - 1]) == SCRIPT_HEBREW
                codes << "C6"
              end
            when 0x30FB
              # KATAKANA MIDDLE DOT: label must also contain Han,
              # Hiragana or Katakana.
              unless cps.any? { |c|
                [SCRIPT_HIRAGANA, SCRIPT_KATAKANA, SCRIPT_HAN].include?(
                  script(c)
                )
              }
                codes << "C7"
              end
            when 0x0660..0x0669
              # ARABIC-INDIC digits must not mix with EXTENDED
              # ARABIC-INDIC digits.
              if cps.any? { |c| (0x06F0..0x06F9).cover?(c) }
                codes << "C8"
              end
            when 0x06F0..0x06F9
              if cps.any? { |c| (0x0660..0x0669).cover?(c) }
                codes << "C8"
              end
            end
          end
        end

        # RFC 5893 Bidi rule, applied to every label once the domain
        # name is known to be a Bidi domain name (at least one label
        # contains an R, AL or AN character).
        def check_label_bidi(info)
          cps = info[:cps]
          return if cps.empty?
          classes = cps.map { |cp| bidi_class(cp) }
          first = classes.first
          # The last character for rules 3 and 6 is the last character
          # that is not a non-spacing mark, if any.
          last = classes.reverse.find { |c| c != BIDI_NSM }
          codes = info[:codes]

          unless first == BIDI_R || first == BIDI_AL
            if first == BIDI_L
              check_ltr_label(classes, last, codes)
            else
              # The first character is not L, R or AL: rule 1 fails
              # (B1) and neither the RTL nor the LTR rules apply.
              codes << "B1"
            end
            return
          end

          # RTL label (first character is R or AL).
          if classes.any? { |c|
            ![BIDI_R, BIDI_AL, BIDI_AN, BIDI_EN, BIDI_ES, BIDI_CS,
              BIDI_ET, BIDI_ON, BIDI_BN, BIDI_NSM].include?(c)
          }
            codes << "B2"
          end
          if last && ![BIDI_R, BIDI_AL, BIDI_EN, BIDI_AN].include?(last)
            codes << "B3"
          end
          if classes.include?(BIDI_EN) && classes.include?(BIDI_AN)
            codes << "B4"
          end
        end

        # RFC 5893 rules 5 and 6 for LTR labels.
        def check_ltr_label(classes, last, codes)
          if classes.any? { |c|
            ![BIDI_L, BIDI_EN, BIDI_ES, BIDI_CS, BIDI_ET, BIDI_ON,
              BIDI_BN, BIDI_NSM].include?(c)
          }
            codes << "B5"
          end
          codes << "B6" if last && last != BIDI_L && last != BIDI_EN
        end

        # True when a validated label contains a character with Bidi
        # class R, AL or AN, making the whole domain a Bidi domain.
        def rtl_label?(cps)
          cps.any? { |cp|
            klass = bidi_class(cp)
            klass == BIDI_R || klass == BIDI_AL || klass == BIDI_AN
          }
        end

        ##
        # Looks up the UTS #46 mapping status and mapping string for a
        # single-character string.
        #
        # @return [Array(Integer, String)] status and mapping (nil when
        #   the status has no mapping).
        def lookup_mapping(char)
          lookup_mapping_cp(char.ord)
        end

        def lookup_mapping_cp(cp)
          row = bsearch_ranges(MAPPING, cp)
          return [STATUS_VALID, nil] unless row
          [row[2], row[3]]
        end

        def bidi_class(cp)
          row = bsearch_ranges(BIDI, cp)
          row ? row[2] : BIDI_L
        end

        def joining_type(cp)
          row = bsearch_ranges(JOINING, cp)
          row ? row[2] : JT_OTHER
        end

        def script(cp)
          row = bsearch_ranges(SCRIPTS, cp)
          row ? row[2] : nil
        end

        def mark?(cp)
          !bsearch_ranges(MARKS, cp).nil?
        end

        def ccc(cp)
          row = bsearch_ranges(CCC, cp)
          row ? row[2] : 0
        end

        def bsearch_ranges(table, cp)
          table.bsearch do |row|
            if cp < row[0]
              -1
            elsif cp > row[1]
              1
            else
              0
            end
          end
        end

        ##
        # Normalizes a string to NFC using the pinned Unicode data in
        # {DECOMPOSE}, {COMPOSE} and {CCC} (plus the algorithmic Hangul
        # rules), so the result does not depend on the Unicode version
        # of the running Ruby.
        def nfc(string)
          cps = []
          string.each_codepoint do |cp|
            canonically_decompose(cp, cps)
          end
          reorder_marks(cps)
          compose_nfc(cps).pack("U*")
        end

        HANGUL_S_BASE = 0xAC00
        HANGUL_L_BASE = 0x1100
        HANGUL_V_BASE = 0x1161
        HANGUL_T_BASE = 0x11A7
        HANGUL_L_COUNT = 19
        HANGUL_V_COUNT = 21
        HANGUL_T_COUNT = 28
        HANGUL_N_COUNT = HANGUL_V_COUNT * HANGUL_T_COUNT
        HANGUL_S_COUNT = HANGUL_L_COUNT * HANGUL_N_COUNT

        def canonically_decompose(cp, output)
          if cp >= HANGUL_S_BASE && cp < HANGUL_S_BASE + HANGUL_S_COUNT
            s_index = cp - HANGUL_S_BASE
            output << HANGUL_L_BASE + s_index / HANGUL_N_COUNT
            output << HANGUL_V_BASE + (s_index % HANGUL_N_COUNT) / HANGUL_T_COUNT
            t = s_index % HANGUL_T_COUNT
            output << HANGUL_T_BASE + t if t > 0
            return
          end
          decomposition = DECOMPOSE[cp]
          if decomposition
            decomposition.each { |part| canonically_decompose(part, output) }
          else
            output << cp
          end
        end

        def reorder_marks(cps)
          i = 1
          while i < cps.length
            klass = ccc(cps[i])
            if klass != 0
              j = i
              while j > 0 && ccc(cps[j - 1]) > klass
                cps[j], cps[j - 1] = cps[j - 1], cps[j]
                j -= 1
              end
            end
            i += 1
          end
          cps
        end

        def compose_nfc(cps)
          return cps if cps.empty?
          output = []
          starter_index = nil
          starter_cp = nil
          last_ccc = 0
          cps.each do |cp|
            klass = ccc(cp)
            composite =
              if starter_index && (last_ccc == 0 || last_ccc < klass)
                compose_pair(starter_cp, cp)
              end
            if composite
              output[starter_index] = composite
              starter_cp = composite
              next
            end
            if klass == 0
              starter_index = output.length
              starter_cp = cp
            end
            output << cp
            last_ccc = klass
          end
          output
        end

        def compose_pair(a, b)
          # Hangul L + V and LV + T composition.
          if a >= HANGUL_L_BASE && a < HANGUL_L_BASE + HANGUL_L_COUNT &&
             b >= HANGUL_V_BASE && b < HANGUL_V_BASE + HANGUL_V_COUNT
            l_index = a - HANGUL_L_BASE
            v_index = b - HANGUL_V_BASE
            return HANGUL_S_BASE +
              (l_index * HANGUL_V_COUNT + v_index) * HANGUL_T_COUNT
          end
          if a >= HANGUL_S_BASE && a < HANGUL_S_BASE + HANGUL_S_COUNT &&
             (a - HANGUL_S_BASE) % HANGUL_T_COUNT == 0 &&
             b > HANGUL_T_BASE && b < HANGUL_T_BASE + HANGUL_T_COUNT
            return a + (b - HANGUL_T_BASE)
          end
          COMPOSE[(a << 21) | b]
        end
      end
    end
  end
end
