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
require "addressable/idna/uts46/tables"

module Addressable
  module IDNA
    ##
    # Pure-Ruby implementation of Unicode IDNA Compatibility Processing
    # (UTS #46), pinned to Unicode 15.1.0 data.
    #
    # This is an alternative to the legacy IDNA2003-compatible conversion
    # in {Addressable::IDNA}. It supports transitional and
    # nontransitional processing, optional STD3 ASCII rules, and performs
    # label length, Bidi (RFC 5893), ContextJ (RFC 5892 Appendix A.1/A.2)
    # and ContextO (RFC 5892 Appendix A.3-A.7) checks.
    #
    # All data is bundled with the gem (see
    # lib/addressable/idna/uts46/tables.rb, generated from the official
    # Unicode IDNA mapping table); nothing is downloaded at runtime and
    # no native library (libidn/ICU) is required.
    #
    # @example
    #   Addressable::IDNA::UTS46.to_ascii("faß.de")
    #   # => "xn--fa-hia.de"
    #   Addressable::IDNA::UTS46.to_ascii("faß.de", transitional: true)
    #   # => "fass.de"
    #   Addressable::IDNA::UTS46.to_unicode("xn--fa-hia.de")
    #   # => "faß.de"
    module UTS46
      ACE_PREFIX = "xn--"

      # Code points with the ContextJ joining rule (RFC 5892 Appendix A).
      CONTEXTJ_CODEPOINTS = [0x200C, 0x200D].freeze

      # Code point ranges with ContextO rules (RFC 5892 Appendix A).
      CONTEXTO_RANGES = [
        [0x00B7, 0x00B7],
        [0x0375, 0x0375],
        [0x05F3, 0x05F4],
        [0x30FB, 0x30FB],
        [0x0660, 0x0669],
        [0x06F0, 0x06F9]
      ].freeze

      ##
      # Raised when a domain name cannot be converted with UTS 46.
      # Carries the offending label and the rule that was violated.
      class Error < StandardError
        # The rule that was violated, e.g. +:bidi+, +:contextj+,
        # +:label_too_long+, +:disallowed_codepoint+.
        attr_reader :rule

        # The label (or domain) that failed.
        attr_reader :label

        # Position of the offending code point within the label, when
        # known.
        attr_reader :position

        def initialize(rule, label: nil, position: nil, message: nil)
          @rule = rule
          @label = label
          @position = position
          super(message || self.class.build_message(rule, label, position))
        end

        def self.build_message(rule, label, position)
          message = +"UTS 46 processing failed (#{rule})"
          message << " at position #{position}" if position
          message << " in label #{label.inspect}" if label
          message
        end
      end

      DEFAULT_OPTIONS = {
        transitional: false,
        use_std3_ascii_rules: false,
        check_hyphens: true,
        check_bidi: true,
        check_joiners: true,
        verify_dns_length: true
      }.freeze

      ##
      # Converts a Unicode domain name to its ASCII (A-label) form using
      # UTS 46 processing.
      #
      # @param [String] domain The domain name to convert.
      # @param [Boolean] transitional Use transitional processing
      #   (deviation characters such as ß are mapped, IDNA2003-style).
      #   Defaults to nontransitional processing.
      # @param [Boolean] use_std3_ascii_rules Apply STD3 ASCII rules:
      #   code points such as "_" that are only valid under relaxed
      #   rules are rejected.
      # @param [Boolean] check_hyphens Enforce the hyphen rules (no
      #   leading/trailing hyphen, no "--" in 3rd and 4th position).
      # @param [Boolean] check_bidi Enforce the Bidi rule (RFC 5893) for
      #   domain names containing right-to-left labels.
      # @param [Boolean] check_joiners Enforce the ContextJ and ContextO
      #   rules (RFC 5892 Appendix A).
      # @param [Boolean] verify_dns_length Enforce DNS length limits
      #   (1-63 octets per label, 253 for the whole domain name).
      # @return [String] The ASCII form of the domain name.
      # @raise [Addressable::IDNA::UTS46::Error] when conversion fails;
      #   the error identifies the offending label and rule.
      def self.to_ascii(domain, **options)
        opts = parse_options(options)
        domain = normalize_input(domain)

        # 1. Map.  2. Normalize (NFC).  3. Break into labels.
        mapped = map_domain(domain, opts, false).unicode_normalize(:nfc)
        labels = mapped.split(".", -1)
        if labels.empty? || (labels.size == 1 && labels[0].empty?)
          raise Error.new(:empty_domain, label: domain)
        end
        trailing_dot = labels.size > 1 && labels[-1].empty?
        labels.pop if trailing_dot

        # 4. Convert/validate each label.
        is_bidi = bidi_domain?(labels)
        out_labels = labels.map do |label|
          if label.empty?
            if opts[:verify_dns_length]
              raise Error.new(:empty_label, label: label)
            end
            label
          elsif label.start_with?(ACE_PREFIX)
            alabel_to_ascii(label, opts, is_bidi)
          else
            ulabel_to_ascii(label, opts, is_bidi)
          end
        end
        out_labels << "" if trailing_dot
        result = out_labels.join(".")

        # 5. Verify DNS length restrictions.
        if opts[:verify_dns_length] && result.length > (trailing_dot ? 254 : 253)
          raise Error.new(:domain_too_long, label: domain)
        end
        result
      end

      ##
      # Converts an ASCII (A-label) domain name to its Unicode (U-label)
      # form. Like the UTS 46 ToUnicode operation, this never fails:
      # labels that cannot be decoded or validated are returned as-is.
      #
      # Takes the same options as {.to_ascii}, except that
      # +verify_dns_length+ does not apply (ToUnicode performs no
      # length verification). When +transitional+ is true, deviation
      # characters are mapped (matching the ToUnicode column of the
      # Unicode IdnaTestV2 transitional test lines); the default is
      # nontransitional mapping.
      #
      # @param [String] domain The domain name to convert.
      # @return [String] The Unicode form of the domain name.
      def self.to_unicode(domain, **options)
        opts = parse_options(options)
        domain = normalize_input(domain)

        mapped = map_domain(domain, opts, true).unicode_normalize(:nfc)
        labels = mapped.split(".", -1)
        is_bidi = bidi_domain?(labels)
        labels.map! do |label|
          if label.start_with?(ACE_PREFIX)
            begin
              decode_alabel(label, opts, is_bidi)
            rescue Error
              label
            end
          else
            begin
              validate_label(label, opts, is_bidi)
            rescue Error
              # ToUnicode never fails; keep the label as-is.
            end
            label
          end
        end
        labels.join(".")
      end

      def self.parse_options(options)
        unknown = options.keys - DEFAULT_OPTIONS.keys
        unless unknown.empty?
          raise ArgumentError, "unknown UTS 46 options: #{unknown.map(&:inspect).join(', ')}"
        end
        DEFAULT_OPTIONS.merge(options)
      end
      private_class_method :parse_options

      def self.normalize_input(domain)
        domain = domain.to_s unless domain.is_a?(String)
        domain = domain.dup.force_encoding(Encoding::UTF_8)
        unless domain.valid_encoding?
          raise Error.new(
            :invalid_input,
            message: "UTS 46 processing failed (invalid_input): input is not valid UTF-8"
          )
        end
        domain
      end
      private_class_method :normalize_input

      # Finds the range entry covering +cp+ in a sorted, non-overlapping
      # range table, or nil.
      def self.range_lookup(ranges, cp)
        index = ranges.bsearch_index { |range| cp <= range[1] }
        return nil if index.nil?
        entry = ranges[index]
        entry[0] <= cp ? entry : nil
      end
      private_class_method :range_lookup

      # Returns the UTS 46 status of a code point and its mapping, if any.
      def self.lookup_status(cp)
        entry = range_lookup(MAPPING_RANGES, cp)
        # The table covers the whole code point space; treat a miss as
        # disallowed defensively.
        entry ? [entry[2], entry[3]] : [:disallowed, nil]
      end
      private_class_method :lookup_status

      def self.bidi_class(cp)
        entry = range_lookup(BIDI_RANGES, cp)
        entry ? entry[2] : "L"
      end
      private_class_method :bidi_class

      def self.joining_type(cp)
        entry = range_lookup(JOINING_RANGES, cp)
        entry ? entry[2] : "U"
      end
      private_class_method :joining_type

      def self.virama?(cp)
        !range_lookup(VIRAMA_RANGES, cp).nil?
      end
      private_class_method :virama?

      def self.mark?(cp)
        !range_lookup(MARK_RANGES, cp).nil?
      end
      private_class_method :mark?

      def self.script?(cp, script)
        !range_lookup(SCRIPT_RANGES.fetch(script), cp).nil?
      end
      private_class_method :script?

      def self.contexto?(cp)
        CONTEXTO_RANGES.any? { |first, last| first <= cp && cp <= last }
      end
      private_class_method :contexto?

      # UTS 46 processing, step 1 (Map). When +keep_disallowed+ is true
      # (ToUnicode), disallowed code points are kept instead of raising.
      def self.map_domain(domain, opts, keep_disallowed)
        out = String.new(encoding: Encoding::UTF_8)
        domain.codepoints.each_with_index do |cp, pos|
          status, mapping = lookup_status(cp)
          case status
          when :valid
            out << cp
          when :ignored
            # dropped
          when :mapped
            out << mapping
          when :deviation
            if opts[:transitional]
              out << mapping
            else
              out << cp
            end
          when :disallowed_STD3_valid
            if opts[:use_std3_ascii_rules]
              raise disallowed_error(cp, domain, pos, "disallowed by STD3 ASCII rules")
            end
            out << cp
          when :disallowed_STD3_mapped
            if opts[:use_std3_ascii_rules]
              raise disallowed_error(cp, domain, pos, "disallowed by STD3 ASCII rules")
            end
            out << mapping
          else
            if keep_disallowed
              out << cp
            else
              raise disallowed_error(cp, domain, pos, "disallowed or unassigned code point")
            end
          end
        end
        out
      end
      private_class_method :map_domain

      def self.disallowed_error(cp, domain, pos, detail)
        label = domain.split(".", -1)[domain[0...pos].count(".")]
        Error.new(
          :disallowed_codepoint,
          label: label,
          position: pos,
          message: format(
            "UTS 46 processing failed (disallowed_codepoint): U+%04X %s in label %s",
            cp, detail, label.inspect
          )
        )
      end
      private_class_method :disallowed_error

      # ToASCII processing for a label that already has the ACE prefix.
      # The label is decoded, validated as a U-label, and re-encoded to
      # its canonical form.
      def self.alabel_to_ascii(label, opts, is_bidi)
        decoded = decode_alabel(label, opts, is_bidi)
        alabel = ACE_PREFIX + encode_punycode(decoded, label)
        verify_label_length!(alabel, label, opts)
        alabel
      end
      private_class_method :alabel_to_ascii

      # ToASCII processing for a U-label or plain ASCII label.
      def self.ulabel_to_ascii(label, opts, is_bidi)
        validate_label(label, opts, is_bidi)
        if label.ascii_only?
          verify_label_length!(label, label, opts)
          label
        else
          alabel = ACE_PREFIX + encode_punycode(label, label)
          verify_label_length!(alabel, label, opts)
          alabel
        end
      end
      private_class_method :ulabel_to_ascii

      # Decodes an A-label to its U-label form, validating it.
      def self.decode_alabel(label, opts, is_bidi)
        punycode = label[ACE_PREFIX.length..]
        if punycode.empty?
          raise Error.new(:invalid_alabel, label: label,
            message: "UTS 46 processing failed (invalid_alabel): A-label has no punycode content in label #{label.inspect}")
        end
        if punycode.end_with?("-")
          raise Error.new(:invalid_alabel, label: label,
            message: "UTS 46 processing failed (invalid_alabel): A-label must not end with a hyphen in label #{label.inspect}")
        end
        decoded = begin
          Punycode.decode(punycode)
        rescue Punycode::BadInput, Punycode::BigOutput, Punycode::Overflow => e
          raise Error.new(:invalid_alabel, label: label,
            message: "UTS 46 processing failed (invalid_alabel): #{e.message} in label #{label.inspect}")
        end
        validate_label(decoded, opts, is_bidi)
        decoded
      end
      private_class_method :decode_alabel

      def self.encode_punycode(label, original_label)
        Punycode.encode(label)
      rescue Punycode::BadInput, Punycode::BigOutput, Punycode::Overflow => e
        raise Error.new(:label_too_long, label: original_label,
          message: "UTS 46 processing failed (label_too_long): #{e.message} in label #{original_label.inspect}")
      end
      private_class_method :encode_punycode

      def self.verify_label_length!(alabel, ulabel, opts)
        if opts[:verify_dns_length] && alabel.bytesize > 63
          raise Error.new(:label_too_long, label: ulabel,
            message: "UTS 46 processing failed (label_too_long): #{alabel.inspect} exceeds 63 octets for label #{ulabel.inspect}")
        end
      end
      private_class_method :verify_label_length!

      # UTS 46 validity criteria for a single U-label.
      def self.validate_label(label, opts, is_bidi)
        cps = label.codepoints
        return if cps.empty?

        # The label must be in Normalization Form C.
        unless label.unicode_normalize(:nfc) == label
          raise Error.new(:nfc, label: label,
            message: "UTS 46 processing failed (nfc): label #{label.inspect} is not in Normalization Form C")
        end

        # Hyphen restrictions (RFC 5891).
        if opts[:check_hyphens]
          if cps[0] == 0x2D || cps[-1] == 0x2D
            raise Error.new(:hyphen, label: label,
              message: "UTS 46 processing failed (hyphen): label #{label.inspect} must not begin or end with a hyphen")
          end
          if cps[2] == 0x2D && cps[3] == 0x2D
            raise Error.new(:hyphen, label: label, position: 2,
              message: "UTS 46 processing failed (hyphen): label #{label.inspect} contains a hyphen in both the 3rd and 4th positions")
          end
        end

        # The label must not begin with a combining mark.
        if mark?(cps[0])
          raise Error.new(:leading_combining_mark, label: label, position: 0,
            message: format("UTS 46 processing failed (leading_combining_mark): label %s begins with U+%04X", label.inspect, cps[0]))
        end

        # Every code point must be valid (a deviation, or valid only
        # when STD3 ASCII rules are relaxed), and contextual rules must
        # hold.
        cps.each_with_index do |cp, pos|
          status, = lookup_status(cp)
          valid = status == :valid || status == :deviation ||
            (status == :disallowed_STD3_valid && !opts[:use_std3_ascii_rules])
          unless valid
            raise Error.new(:disallowed_codepoint, label: label, position: pos,
              message: format("UTS 46 processing failed (disallowed_codepoint): U+%04X is not allowed in label %s", cp, label.inspect))
          end
          next unless opts[:check_joiners]
          if CONTEXTJ_CODEPOINTS.include?(cp)
            unless valid_contextj(cps, pos)
              raise Error.new(:contextj, label: label, position: pos,
                message: format("UTS 46 processing failed (contextj): U+%04X is not allowed at position %d in label %s", cp, pos, label.inspect))
            end
          elsif contexto?(cp)
            unless valid_contexto(cps, pos)
              raise Error.new(:contexto, label: label, position: pos,
                message: format("UTS 46 processing failed (contexto): U+%04X is not allowed at position %d in label %s", cp, pos, label.inspect))
            end
          end
        end

        check_bidi(cps, label) if opts[:check_bidi] && is_bidi
      end
      private_class_method :validate_label

      # RFC 5892 Appendix A.1/A.2: the ContextJ rule for ZERO WIDTH
      # NON-JOINER (U+200C) and ZERO WIDTH JOINER (U+200D).
      def self.valid_contextj(cps, pos)
        cp = cps[pos]
        if cp == 0x200C
          return true if pos > 0 && virama?(cps[pos - 1])
          ok = false
          (pos - 1).downto(0) do |i|
            jt = joining_type(cps[i])
            if jt == "T"
              next
            elsif jt == "L" || jt == "D"
              ok = true
              break
            else
              break
            end
          end
          return false unless ok
          ok = false
          ((pos + 1)...cps.size).each do |i|
            jt = joining_type(cps[i])
            if jt == "T"
              next
            elsif jt == "R" || jt == "D"
              ok = true
              break
            else
              break
            end
          end
          ok
        elsif cp == 0x200D
          pos > 0 && virama?(cps[pos - 1])
        else
          false
        end
      end
      private_class_method :valid_contextj

      # RFC 5892 Appendix A.3-A.7: the ContextO rules.
      def self.valid_contexto(cps, pos)
        cp = cps[pos]
        case cp
        when 0x00B7
          pos > 0 && pos < cps.size - 1 &&
            cps[pos - 1] == 0x006C && cps[pos + 1] == 0x006C
        when 0x0375
          pos < cps.size - 1 && cps.size > 1 && script?(cps[pos + 1], "Greek")
        when 0x05F3, 0x05F4
          pos > 0 && script?(cps[pos - 1], "Hebrew")
        when 0x30FB
          cps.any? do |other|
            other != 0x30FB &&
              (script?(other, "Hiragana") || script?(other, "Katakana") || script?(other, "Han"))
          end
        when 0x0660..0x0669
          cps.none? { |other| (0x06F0..0x06F9).cover?(other) }
        when 0x06F0..0x06F9
          cps.none? { |other| (0x0660..0x0669).cover?(other) }
        else
          false
        end
      end
      private_class_method :valid_contexto

      # A domain name is a "Bidi domain name" (RFC 5893) when any of its
      # labels contains a code point with Bidi class R, AL or AN.
      def self.bidi_domain?(labels)
        labels.any? do |label|
          decoded = label
          if label.start_with?(ACE_PREFIX)
            punycode = label[ACE_PREFIX.length..]
            decoded = begin
              Punycode.decode(punycode)
            rescue Punycode::BadInput, Punycode::BigOutput, Punycode::Overflow
              ""
            end
          end
          decoded.codepoints.any? { |cp| %w[R AL AN].include?(bidi_class(cp)) }
        end
      end
      private_class_method :bidi_domain?

      RTL_ALLOWED_BIDI_CLASSES = %w[R AL AN EN ES CS ET ON BN NSM].freeze
      LTR_ALLOWED_BIDI_CLASSES = %w[L EN ES CS ET ON BN NSM].freeze

      # The Bidi Rule (RFC 5893), applied to every label of a Bidi
      # domain name.
      def self.check_bidi(cps, label)
        first = bidi_class(cps[0])
        rtl = case first
        when "R", "AL"
          true
        when "L"
          false
        else
          raise Error.new(:bidi, label: label, position: 0,
            message: "UTS 46 processing failed (bidi): first code point of label #{label.inspect} must have Bidi class L, R or AL")
        end

        valid_ending = false
        number_type = nil
        cps.each_with_index do |cp, pos|
          direction = bidi_class(cp)
          if rtl
            unless RTL_ALLOWED_BIDI_CLASSES.include?(direction)
              raise Error.new(:bidi, label: label, position: pos,
                message: format("UTS 46 processing failed (bidi): Bidi class %s is not allowed in right-to-left label %s", direction, label.inspect))
            end
            if %w[R AL EN AN].include?(direction)
              valid_ending = true
            elsif direction != "NSM"
              valid_ending = false
            end
            if direction == "AN" || direction == "EN"
              if number_type.nil?
                number_type = direction
              elsif number_type != direction
                raise Error.new(:bidi, label: label, position: pos,
                  message: "UTS 46 processing failed (bidi): cannot mix European and Arabic-Indic digits in right-to-left label #{label.inspect}")
              end
            end
          else
            unless LTR_ALLOWED_BIDI_CLASSES.include?(direction)
              raise Error.new(:bidi, label: label, position: pos,
                message: format("UTS 46 processing failed (bidi): Bidi class %s is not allowed in left-to-right label %s", direction, label.inspect))
            end
            if direction == "L" || direction == "EN"
              valid_ending = true
            elsif direction != "NSM"
              valid_ending = false
            end
          end
        end

        unless valid_ending
          raise Error.new(:bidi, label: label,
            message: "UTS 46 processing failed (bidi): label #{label.inspect} ends with an illegal Bidi class")
        end
      end
      private_class_method :check_bidi
    end
  end
end
