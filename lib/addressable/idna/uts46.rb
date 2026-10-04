# frozen_string_literal: true

require "json"

module Addressable
  module IDNA
    # Profiles and tables for Unicode UTS #46, generated for Unicode 15.1.0.
    UNICODE_VERSION = "15.1.0"

    class IdnaError < StandardError
      attr_reader :errors_by_label

      def initialize(message = nil, errors_by_label: {})
        super(message)
        @errors_by_label = errors_by_label
      end
    end

    class Profile
      attr_reader :transitional, :use_std3_ascii_rules, :check_hyphens,
        :check_bidi, :check_joiners, :check_context_o, :verify_dns_length

      def initialize(transitional: false, use_std3_ascii_rules: false,
                     check_hyphens: false, check_bidi: false,
                     check_joiners: false, check_context_o: false,
                     verify_dns_length: false)
        @transitional = transitional
        @use_std3_ascii_rules = use_std3_ascii_rules
        @check_hyphens = check_hyphens
        @check_bidi = check_bidi
        @check_joiners = check_joiners
        @check_context_o = check_context_o
        @verify_dns_length = verify_dns_length
      end

      def to_ascii(input)
        UTS46.process(input, self, true)
      end

      def to_unicode(input)
        UTS46.process(input, self, false)
      end

      def to_ascii!(input)
        to_ascii(input).value!
      end

      def to_unicode!(input)
        to_unicode(input).value!
      end
    end

    Result = Struct.new(:to_s, :error, :errors_by_label) do
      def success?
        error.nil?
      end

      def value!
        raise error if error
        to_s
      end
    end

    UTS46_PROFILE = Profile.new
    TRANSITIONAL_PROFILE = Profile.new(transitional: true)
    STRICT_PROFILE = Profile.new(
      use_std3_ascii_rules: true,
      check_hyphens: true,
      check_bidi: true,
      check_joiners: true,
      check_context_o: true,
      verify_dns_length: true
    )
    REGISTRATION_PROFILE = STRICT_PROFILE
    NONTRANSITIONAL_PROFILE = Profile.new
    DISPLAY_PROFILE = Profile.new(check_context_o: true)

    module UTS46
      ACE_PREFIX = "xn--"
      MAX_LABEL_LENGTH = 63
      MAX_DOMAIN_LENGTH = 253
      SEVERE_ERRORS = [
        :punycode, :invalid_ace, :empty_label, :leading_combining_mark,
        :disallowed, :label_has_dot
      ].freeze

      module_function

      def process(input, profile, to_ascii)
        codepoints = prepare(input)
        processed = nfc(map(codepoints, profile))
        labels = split_labels(processed)

        results = labels.map do |label|
          process_label(label, profile, to_ascii)
        end
        check_bidi(results, profile)
        verify_length(results, profile, to_ascii)

        output = results.map { |result| result[:output].pack("U*") }.join(".")
        errors = results.each_with_index.each_with_object({}) do |(result, index), memo|
          memo[index] = result[:errors] unless result[:errors].empty?
        end
        error = IdnaError.new("Invalid IDNA domain name", errors_by_label: errors) unless errors.empty?
        output = output.force_encoding(Encoding::UTF_8)
        Result.new(output, error, errors)
      end

      def prepare(input)
        value = input.is_a?(String) ? input.dup : input.to_s
        value.force_encoding(Encoding::UTF_8)
        unless value.valid_encoding?
          value = value.encode(
            Encoding::UTF_8,
            invalid: :replace,
            undef: :replace,
            replace: "\uFFFD"
          )
        end
        codepoints = value.unpack("U*")
        codepoints
      end

      def split_labels(codepoints)
        labels = [[]]
        codepoints.each do |codepoint|
          if codepoint == 0x2E
            labels << []
          else
            labels.last << codepoint
          end
        end
        labels
      end

      def process_label(label, profile, to_ascii)
        ace = ascii?(label) && label.length >= 4 && label[0, 4].map(&:chr).join == ACE_PREFIX
        decoded = false
        original_output = label
        errors = []

        if ace
          begin
            decoded_label = punycode_decode(label[4..-1])
            decoded = true
          rescue StandardError
            return bad_ace(original_output, [:punycode])
          end
          label = nfc(map(decoded_label, NONTRANSITIONAL_PROFILE))
          errors << :invalid_ace if label != decoded_label
          errors << :invalid_ace if !decoded_label.empty? &&
            label.all? { |codepoint| codepoint < 0x80 }
        end

        errors << :invalid_ace if decoded && label.empty?

        errors.concat(validate(label, profile, decoded ? false : profile.transitional))
        output = label

        if to_ascii
          output = original_output if decoded
          if !decoded && label.any? { |codepoint| codepoint >= 0x80 }
            begin
              output = ACE_PREFIX.codepoints.to_a + punycode_encode(label)
            rescue StandardError
              errors << :punycode
              output = label
            end
          end
          if profile.verify_dns_length && ascii?(output) && output.length > MAX_LABEL_LENGTH
            errors << :label_too_long
          end
        end

        if errors.include?(:punycode) || errors.include?(:invalid_ace)
          output = original_output
        end
        { output: output, errors: errors.uniq, decoded: decoded, valid_label: label }
      end

      def bad_ace(label, errors)
        { output: label, errors: errors.uniq, decoded: false, valid_label: nil }
      end

      def validate(label, profile, transitional)
        errors = []
        return errors.concat([:empty_label]) if label.empty?

        errors << :hyphen_3_4 if profile.check_hyphens && label.length >= 4 && label[2] == 0x2D && label[3] == 0x2D
        errors << :leading_hyphen if profile.check_hyphens && label.first == 0x2D
        errors << :trailing_hyphen if profile.check_hyphens && label.last == 0x2D
        errors << :label_has_dot if label.include?(0x2E)
        errors << :leading_combining_mark if member?(label.first, "mark")

        label.each do |codepoint|
          status, = mapping(codepoint)
          if profile.use_std3_ascii_rules && codepoint <= 0x7F
            unless (codepoint >= 0x61 && codepoint <= 0x7A) ||
                (codepoint >= 0x30 && codepoint <= 0x39) || codepoint == 0x2D
              errors << :disallowed_std3
            else
              if transitional
                errors << :disallowed unless status == "valid"
              elsif !%w[valid deviation disallowed_STD3_valid].include?(status)
                errors << :disallowed
              end
            end
          elsif transitional
            errors << :disallowed unless status == 'valid'
          elsif !%w[valid deviation disallowed_STD3_valid disallowed_STD3_mapped].include?(status)
            errors << :disallowed
          end
        end

        errors << :context_j if profile.check_joiners && !valid_context_j?(label)
        errors.concat(context_o_errors(label)) if profile.check_context_o
        errors
      end

      def check_bidi(results, profile)
        return unless profile.check_bidi
        bidi = results.any? do |result|
          valid_label = result[:valid_label]
          valid_label && valid_label.any? do |codepoint|
            %w[Right_To_Left Arabic_Letter Arabic_Number].include?(bidi_class(codepoint))
          end
        end
        return unless bidi
        results.each do |result|
          next unless result[:valid_label] && !result[:valid_label].empty?
          next if (result[:errors] & SEVERE_ERRORS).any?
          result[:errors] << :bidi unless valid_bidi?(result[:valid_label])
        end
      end

      def verify_length(results, profile, to_ascii)
        return unless to_ascii && profile.verify_dns_length
        results.each_with_index do |result, _index|
          result[:errors] << :empty_label if result[:output].empty?
          result[:errors] << :label_too_long if result[:output].length > MAX_LABEL_LENGTH
        end
        length = results.map { |result| result[:output] }.join(".").length
        results.each { |result| result[:errors].uniq! }
        domain_error = length == 0 || length > MAX_DOMAIN_LENGTH + 1 ||
          (length == MAX_DOMAIN_LENGTH + 1 && !results.last[:output].empty?)
        results.first[:errors] << :domain_name_too_long if domain_error
      end

      def valid_bidi?(label)
        first = bidi_class(label.first)
        return false unless %w[Left_To_Right Right_To_Left Arabic_Letter].include?(first)
        rtl = %w[Right_To_Left Arabic_Letter].include?(first)
        last = label.reverse_each.detect do |codepoint|
          bidi_class(codepoint) != "Nonspacing_Mark"
        end
        last_class = bidi_class(last)
        classes = label.map { |codepoint| bidi_class(codepoint) }.uniq
        if rtl
          allowed = %w[Right_To_Left Arabic_Letter Arabic_Number European_Number
                       European_Separator Common_Separator European_Terminator
                       Other_Neutral Boundary_Neutral Nonspacing_Mark]
          return false unless (classes - allowed).empty?
          return false unless %w[Right_To_Left Arabic_Letter European_Number Arabic_Number].include?(last_class)
          return !(classes.include?("European_Number") && classes.include?("Arabic_Number"))
        else
          allowed = %w[Left_To_Right European_Number European_Separator Common_Separator
                       European_Terminator Other_Neutral Boundary_Neutral Nonspacing_Mark]
          return false unless (classes - allowed).empty?
          %w[Left_To_Right European_Number].include?(last_class)
        end
      end

      def valid_context_j?(label)
        label.each_with_index do |codepoint, index|
          next unless codepoint == 0x200C || codepoint == 0x200D
          before_index = index - 1
          while before_index >= 0 && joining_type_name(label[before_index]) == "Transparent"
            before_index -= 1
          end
          return false if before_index < 0
          before = label[before_index]
          next if combining_class(before) == 9
          return false if codepoint == 0x200D

          while before_index >= 0 && joining_type_name(label[before_index]) == "Transparent"
            before_index -= 1
          end
          after_index = index + 1
          while after_index < label.length && joining_type_name(label[after_index]) == "Transparent"
            after_index += 1
          end
          before_type = before_index >= 0 ? joining_type_name(label[before_index]) : nil
          after_type = after_index < label.length ? joining_type_name(label[after_index]) : nil
          return false unless %w[Dual_Joining Left_Joining].include?(before_type)
          return false unless %w[Dual_Joining Right_Joining].include?(after_type)
        end
        true
      end


      def context_o_errors(label)
        errors = []
        arabic_digits = 0
        label.each_with_index do |codepoint, index|
          case codepoint
          when 0x00B7
            errors << :context_o_punctuation unless index > 0 && label[index - 1] == 0x6C &&
              index + 1 < label.length && label[index + 1] == 0x6C
          when 0x0375
            following = label[index + 1]
            errors << :context_o_punctuation unless following && script?(following, "Greek")
          when 0x05F3, 0x05F4
            preceding = index.zero? ? nil : label[index - 1]
            errors << :context_o_punctuation unless preceding && script?(preceding, "Hebrew")
          when 0x30FB
            errors << :context_o_punctuation unless label.any? do |other|
              %w[Hiragana Katakana Han].any? { |script| script?(other, script) }
            end
          when 0x0660..0x0669
            errors << :context_o_digits if arabic_digits == 1
            arabic_digits = -1
          when 0x06F0..0x06F9
            errors << :context_o_digits if arabic_digits == -1
            arabic_digits = 1
          end
        end
        errors
      end

      def map(codepoints, profile)
        codepoints.each_with_object([]) do |codepoint, output|
          status, mapping = mapping(codepoint)
          case status
          when "ignored"
          when "mapped"
            if profile.transitional && codepoint == 0x1E9E
              output.concat([0x73, 0x73])
            else
              output.concat(mapping)
            end
          when "deviation"
            if profile.transitional
              output.concat(deviation_mapping(codepoint))
            else
              output << codepoint
            end
          else
            output << codepoint
          end
        end
      end

      def deviation_mapping(codepoint)
        case codepoint
        when 0x00DF then [0x73, 0x73]
        when 0x03C2 then [0x03C3]
        when 0x200C, 0x200D then []
        else [codepoint]
        end
      end

      def nfc(codepoints)
        compose(nfd(codepoints))
      end

      def nfd(codepoints)
        decomposed = codepoints.flat_map do |codepoint|
          hangul_decomposition(codepoint) ||
            canonical_decomposition(codepoint) || [codepoint]
        end
        reorder_canonical(decomposed)
      end

      def hangul_decomposition(codepoint)
        if (0xAC00..0xD7A3).include?(codepoint)
          index = codepoint - 0xAC00
          l = 0x1100 + index / (21 * 28)
          v = 0x1161 + (index % (21 * 28)) / 28
          t = index % 28
          [l, v] + (t.zero? ? [] : [0x11A7 + t])
        end
      end

      def reorder_canonical(codepoints)
        output = []
        codepoints.each do |codepoint|
          current_class = combining_class(codepoint)
          if current_class.zero? || output.empty?
            output << codepoint
          else
            target = output.length
            while target > 0
              previous = output[target - 1]
              previous_class = combining_class(previous)
              break if previous_class.zero? || previous_class <= current_class
              target -= 1
            end
            output.insert(target, codepoint)
          end
        end
        output
      end

      def compose(codepoints)
        compose_hangul(compose_non_hangul(codepoints))
      end

      def compose_non_hangul(codepoints)
        output = []
        starter = nil
        last_class = 0
        blocked = false

        codepoints.each do |codepoint|
          if hangul_character?(codepoint)
            output << codepoint
            starter = output.length - 1
            last_class = 0
            blocked = false
            next
          end

          current_class = combining_class(codepoint)
          if current_class.zero?
            if starter
              composed = canonical_composition(output[starter], codepoint)
              if composed
                output[starter] = composed
                last_class = 0
                blocked = false
                next
              end
            end
            output << codepoint
            starter = output.length - 1
            last_class = 0
            blocked = false
          elsif starter.nil?
            output << codepoint
          else
            target = output.length - 1
            local_blocked = false
            unless blocked
              while target > starter
                previous_class = combining_class(output[target])
                if previous_class != 0 && previous_class < current_class
                  local_blocked = true
                else
                  composed = canonical_composition(output[target], codepoint) ||
                    hangul_compose(output[target], codepoint)
                  if composed
                    output[target] = composed
                    target = nil
                    break
                  end
                end
                target -= 1
              end
            end

            if !target.nil? && target == starter && !blocked
              composed = canonical_composition(output[starter], codepoint)
              if composed
                output[starter] = composed
                blocked = local_blocked
              else
                output << codepoint
                blocked = blocked || local_blocked ||
                  (last_class > 0 && current_class >= last_class)
              end
            elsif !target.nil?
              output << codepoint
              blocked = blocked || local_blocked ||
                (last_class > 0 && current_class >= last_class)
            end
            last_class = current_class
          end
        end
        output
      end

      def compose_hangul(codepoints)
        output = []
        codepoints.each do |codepoint|
          if output.any?
            composed = hangul_compose(output.last, codepoint)
            if composed
              output[-1] = composed
              next
            end
          end
          output << codepoint
        end
        output
      end

      def hangul_character?(codepoint)
        (0x1100..0x11FF).include?(codepoint) || (0xAC00..0xD7AF).include?(codepoint)
      end

      def hangul_compose(first, second)
        if (0x1100..0x1112).include?(first) && (0x1161..0x1175).include?(second)
          0xAC00 + ((first - 0x1100) * 21 + (second - 0x1161)) * 28
        elsif (0xAC00..0xD7A3).include?(first) &&
            (first - 0xAC00) % 28 == 0 && (0x11A8..0x11C2).include?(second)
          first + (second - 0x11A7)
        end
      end

      def mapping(codepoint)
        entry = lookup_data("mappings", codepoint)
        entry ? [entry[0], entry[1]] : ["disallowed", [0xFFFD]]
      end

      def combining_class(codepoint)
        data["ccc"][codepoint.to_s] || 0
      end

      def canonical_decomposition(codepoint)
        value = data["canonical_decomposition"][codepoint.to_s]
        value && value.flat_map { |part| canonical_decomposition(part) || [part] }
      end

      def canonical_composition(first, second)
        data["canonical_composition"]["#{first}/#{second}"]
      end

      def member?(codepoint, group, name = nil)
        ranges = name ? data["properties"][group][name] : data["properties"][group]
        lookup_ranges(ranges, codepoint)
      end

      def bidi_class(codepoint)
        return "Left_To_Right" if codepoint < 0x80
        data["properties"]["bidi"].each do |name, ranges|
          return name if lookup_ranges(ranges, codepoint)
        end
        nil
      end

      def joining_type_name(codepoint)
        data["properties"]["joining"].each do |name, ranges|
          return name if lookup_ranges(ranges, codepoint)
        end
        "Non_Joining"
      end

      def script?(codepoint, script)
        lookup_ranges(data["properties"]["scripts"][script], codepoint)
      end

      def lookup_data(key, codepoint)
        ranges = data[key]
        low = 0
        high = ranges.length - 1
        while low <= high
          middle = (low + high) / 2
          entry = ranges[middle]
          finish = entry[1] || entry[0]
          return entry[2..-1] if codepoint >= entry[0] && codepoint <= finish
          if codepoint < entry[0]
            high = middle - 1
          else
            low = middle + 1
          end
        end
        nil
      end

      def lookup_ranges(ranges, codepoint)
        low = 0
        high = ranges.length - 1
        while low <= high
          middle = (low + high) / 2
          entry = ranges[middle]
          start = entry.is_a?(Array) ? entry[0] : entry
          finish = entry.is_a?(Array) ? entry[1] : entry
          return true if codepoint >= start && codepoint <= finish
          if codepoint < start
            high = middle - 1
          else
            low = middle + 1
          end
        end
        false
      end

      def ascii?(codepoints)
        codepoints.all? { |codepoint| codepoint <= 0x7F }
      end

      def punycode_encode(codepoints)
        Addressable::IDNA.send(:punycode_encode, codepoints.pack("U*")).bytes
      end

      def punycode_decode(value)
        Addressable::IDNA.send(:punycode_decode, value.pack("U*")).unpack("U*")
      end

      def data
        @data ||= JSON.parse(File.read(File.expand_path(
          "../data/uts46-#{UNICODE_VERSION}.json",
          __FILE__
        )))
      end
    end
  end
end
