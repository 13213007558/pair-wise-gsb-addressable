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


require "addressable/version"
require "addressable/uri"

module Addressable
  ##
  # This is an implementation of a URI template based on
  # RFC 6570 (http://tools.ietf.org/html/rfc6570).
  class Template
    # Constants used throughout the template code.
    anything =
      Addressable::URI::CharacterClasses::RESERVED +
      Addressable::URI::CharacterClasses::UNRESERVED


    variable_char_class =
      Addressable::URI::CharacterClasses::ALPHA +
      Addressable::URI::CharacterClasses::DIGIT + '_'

    var_char =
      "(?>(?:[#{variable_char_class}]|%[a-fA-F0-9][a-fA-F0-9])+)"
    RESERVED =
      "(?:[#{anything}]|%[a-fA-F0-9][a-fA-F0-9])"
    RESERVED_NO_COMMA =
      "(?:[#{anything.delete(',')}]|%[a-fA-F0-9][a-fA-F0-9])"
    UNRESERVED =
      "(?:[#{
        Addressable::URI::CharacterClasses::UNRESERVED
      }]|%[a-fA-F0-9][a-fA-F0-9])"
    variable =
      "(?:#{var_char}(?:\\.?#{var_char})*)"
    varspec =
      "(?:(#{variable})(\\*|:\\d+)?)"
    VARNAME =
      /^#{variable}$/
    VARSPEC =
      /^#{varspec}$/
    VARIABLE_LIST =
      /^#{varspec}(?:,#{varspec})*$/
    operator =
      "+#./;?&=,!@|"
    EXPRESSION =
      /\{([#{operator}])?(#{varspec}(?:,#{varspec})*)\}/


    LEADERS = {
      '?' => '?',
      '/' => '/',
      '#' => '#',
      '.' => '.',
      ';' => ';',
      '&' => '&'
    }
    JOINERS = {
      '?' => '&',
      '.' => '.',
      ';' => ';',
      '&' => '&',
      '/' => '/'
    }

    ##
    # Raised if an invalid template value is supplied.
    class InvalidTemplateValueError < StandardError
    end

    ##
    # Raised if an invalid template operator is used in a pattern.
    class InvalidTemplateOperatorError < StandardError
    end

    ##
    # Raised if an invalid template operator is used in a pattern.
    class TemplateOperatorAbortedError < StandardError
    end

    ##
    # This class represents the result of a strict reverse template match.
    # Unlike {Addressable::Template::MatchData}, it retains every candidate
    # that can be expanded back to the original URI.
    class StrictMatchData
      # Creates a new StrictMatchData object.
      # StrictMatchData objects should never be instantiated directly.
      #
      # @param [Addressable::URI] uri The URI that was matched.
      # @param [Addressable::Template] template The template used for matching.
      # @param [Hash] types The variable types used for matching.
      # @param [Array<Hash>] candidates The valid candidate mappings.
      # @param [Boolean] incomplete Whether prefix truncation left unknown data.
      # @param [Boolean] truncated Whether candidate enumeration was truncated.
      # @param [Integer] limit The maximum number of candidates to retain.
      def initialize(uri, template, types, candidates, incomplete, truncated,
                     limit)
        @uri = uri.dup.freeze
        @template = template
        @types = types.dup.freeze
        @candidates = candidates.map { |candidate| candidate.dup.freeze }.freeze
        @incomplete = incomplete
        @truncated = truncated
        @limit = limit
      end

      # @return [Addressable::URI] The URI that was matched.
      attr_reader :uri

      # @return [Addressable::Template] The template used for matching.
      attr_reader :template

      # @return [Hash] The variable types used for matching.
      attr_reader :types

      # @return [Array<Hash>] All retained mappings that re-expand to the URI.
      attr_reader :candidates

      # @return [Integer] The maximum number of candidates to retain.
      attr_reader :limit

      # @return [Symbol] One of +:unique+, +:multiple+, +:no_match+,
      #   +:truncated+, or +:incomplete+.
      def status
        if candidates.empty? && !incomplete?
          :no_match
        elsif truncated?
          :truncated
        elsif incomplete?
          :incomplete
        elsif candidates.length == 1
          :unique
        else
          :multiple
        end
      end

      # @return [Boolean] Whether at least one candidate was found.
      def match?
        !candidates.empty?
      end

      # @return [Boolean] Whether there is exactly one complete candidate.
      def unique?
        status == :unique
      end

      # @return [Boolean] Whether there is more than one complete candidate.
      def multiple?
        status == :multiple
      end

      # @return [Boolean] Whether no candidate was found.
      def no_match?
        status == :no_match
      end

      # @return [Boolean] Whether the candidate limit was reached.
      def truncated?
        @truncated
      end

      # @return [Boolean] Whether a prefix modifier leaves unknown suffix data.
      def incomplete?
        @incomplete
      end

      # @return [Hash, nil] The unique candidate, or nil when not unique.
      def mapping
        candidates.first if unique?
      end
      alias_method :to_h, :mapping

      # @return [String] A representation of the result.
      def inspect
        sprintf(
          "#<%s:%#0x STATUS:%s CANDIDATES:%d%s>",
          self.class.to_s, self.object_id, self.status.inspect,
          candidates.length,
          truncated? ? " TRUNCATED" : ""
        )
      end
    end

    def strict_each_nonform_list(raw, operator, variable, prior, context,
                                 consume_all=false)
      separator = JOINERS.fetch(operator, ",")
      start = 0
      if prior
        return unless raw.start_with?(separator)
        start = separator.length
      end
      remaining = raw[start..-1] || ""
      item_separator = variable["explode"] ? separator : ","
      positions = strict_split_positions(remaining, item_separator, operator,
                                         variable["explode"])
      strict_enumerate_partitions(remaining, positions, context, consume_all) do |groups, consumed|
        if groups.empty?
          yield [], "", nil
        else
          values = groups.map do |group|
            strict_decode_scalar(group, operator)
          end
          unless values.any?(&:nil?)
            yield values, raw[(start + consumed)..-1] || "", nil
          end
        end
      end
    end

    def strict_each_nonform_map(raw, operator, variable, prior, context,
                                consume_all=false)
      separator = JOINERS.fetch(operator, ",")
      start = 0
      if prior
        return unless raw.start_with?(separator)
        start = separator.length
      end
      remaining = raw[start..-1] || ""
      field_separator = variable["explode"] ? separator : ","
      positions = strict_split_positions(remaining, field_separator, operator,
                                         true)
      strict_enumerate_partitions(remaining, positions, context, consume_all) do |fields, consumed, chosen|
        if variable["explode"]
          next unless fields.length >= 1
          pairs = strict_decode_map_fields(fields, operator, true)
        else
          next unless fields.length >= 2 && fields.length.even?
          if field_separator == "," && %w(+ #).include?(operator)
            next unless chosen.sort == positions.select { |position|
              position < consumed
            }.sort
          end
          pairs = strict_decode_map_fields(fields, operator, false)
        end
        if pairs
          value = {}
          pairs.each { |key, val| value[key] = val }
          if value.length == pairs.length
            yield value, raw[(start + consumed)..-1] || "", nil
          end
        end
      end
    end

    def strict_split_positions(string, separator, operator, explode)
      string.each_char.with_index.select do |char, _|
        char == separator
      end.map { |_, index| index }
    end

    def strict_enumerate_partitions(string, separator_positions, context,
                                   consume_all=false)
      catch(:strict_limit) do
        if string.empty?
          yield [], 0, []
        elsif consume_all
          available = separator_positions.select { |position| position < string.length }
          (0..available.length).each do |count|
            available.combination(count) do |chosen|
              throw :strict_limit if context
              boundaries = [-1] + chosen + [string.length]
              groups = boundaries.each_cons(2).map do |start_position, end_position|
                string[(start_position + 1)...end_position]
              end
              yield groups, string.length, chosen
            end
          end
        else
          stop_positions = separator_positions + [string.length]
          0.upto(stop_positions.length) do |count|
            stop_positions.each do |stop|
              available = separator_positions.select { |position| position < stop }
              next unless available.length >= count
              available.combination(count) do |chosen|
                throw :strict_limit if context
                boundaries = [-1] + chosen + [stop]
                groups = boundaries.each_cons(2).map do |start_position, end_position|
                  string[(start_position + 1)...end_position]
                end
                yield groups, stop, chosen
              end
            end
          end
        end
      end
    end

    def strict_decode_map_fields(fields, operator, explode)
      pairs = []
      fields.each do |field|
        if explode
          equals = field.enum_for(:scan, /=/).map do
            Regexp.last_match.begin(0)
          end
          return nil if equals.empty?
          decoded_pairs = equals.map do |position|
            key = strict_decode_scalar(field[0...position], operator)
            value = strict_decode_scalar(field[(position + 1)..-1], operator)
            [key, value]
          end
          return nil unless decoded_pairs.length == 1
          pairs.concat(decoded_pairs)
        else
          decoded = strict_decode_scalar(field, operator)
          return nil if decoded.nil?
          pairs << decoded
        end
      end
      return pairs.each_slice(2).to_a unless explode
      pairs
    end

    def strict_parse_form(raw, operator, vars, index, mapping, prefixes, prior,
                         context, &block)
      if index >= vars.length
        yield mapping, prefixes, strict_prefixes_partial?(prefixes) if raw.empty?
        return
      end

      variable = vars[index]
      name = variable["name"]
      type = variable["type"]
      separator = JOINERS.fetch(operator, "&")

      strict_parse_form(raw, operator, vars, index + 1, mapping, prefixes,
                        prior, context, &block)

      start = 0
      if prior
        return unless raw.start_with?(separator)
        start = separator.length
      end
      remaining = raw[start..-1] || ""
      boundary = strict_field_boundary(remaining, separator)
      field = remaining[0...boundary]
      tail = remaining[boundary..-1] || ""

      case type
      when :scalar
        value = strict_form_scalar(name, field, operator, variable)
        if value
          merged = strict_add_value(mapping, prefixes, name, value[0], value[1])
          strict_parse_form(tail, operator, vars, index + 1, merged[0],
                            merged[1], true, context, &block) if merged
        end
      when :list
        if variable["explode"]
          strict_each_form_explode_list(remaining, separator, name, operator) do |value, next_raw|
            merged = strict_add_value(mapping, prefixes, name, value, nil)
            next unless merged
            strict_parse_form(next_raw, operator, vars, index + 1, merged[0],
                              merged[1], false, context, &block)
          end
        elsif field.empty? || field == name
          merged = strict_add_value(mapping, prefixes, name, [], nil)
          next_tail = (field == name && operator == ";") ? tail[1..-1] || "" : tail
          strict_parse_form(next_tail, operator, vars, index + 1, merged[0],
                            merged[1], false, context, &block) if merged
        elsif field.start_with?("#{name}=")
          items = field[(name.length + 1)..-1].split(",", -1)
          values = items.map { |item| strict_decode_scalar(item, operator) }
          unless values.any?(&:nil?)
            merged = strict_add_value(mapping, prefixes, name, values, nil)
            strict_parse_form(tail, operator, vars, index + 1, merged[0],
                              merged[1], true, context, &block) if merged
          end
        end
      when :map
        empty_merged = strict_add_value(mapping, prefixes, name, Hash.new, nil)
        if empty_merged
          strict_parse_form(raw, operator, vars, index + 1, empty_merged[0],
                             empty_merged[1], prior, context, &block)
        end
        if variable["explode"]
          strict_each_form_explode_map(remaining, separator, operator) do |value, next_raw|
            merged = strict_add_value(mapping, prefixes, name, value, nil)
            next unless merged
            strict_parse_form(next_raw, operator, vars, index + 1, merged[0],
                              merged[1], false, context, &block)
          end
        elsif field.start_with?(name + "=")
          encoded_pairs = field[(name.length + 1)..-1].split(",", -1)
          if encoded_pairs.length >= 2 && encoded_pairs.length.even?
            pairs = strict_decode_map_fields(encoded_pairs, operator, false)
            if pairs
              value = {}
              pairs.each { |key, val| value[key] = val }
              if value.length == pairs.length
                merged = strict_add_value(mapping, prefixes, name, value, nil)
                if merged
                  strict_parse_form(tail, operator, vars, index + 1, merged[0],
                                    merged[1], true, context, &block)
                end
              end
            end
          end
        end
      end
    end

    def strict_field_boundary(string, separator)
      string.index(separator) || string.length
    end

    def strict_form_scalar(name, field, operator, variable)
      if operator == ";" && field == name
        ["", nil]
      elsif field.start_with?("#{name}=")
        raw_value = field[(name.length + 1)..-1]
        value = strict_decode_scalar(raw_value, operator)
        return nil if value.nil?
        prefix = variable["prefix"]
        if prefix && (prefix == 0 || value.length >= prefix)
          observed = value[0...prefix]
          expected = strict_encode_scalar(observed, operator)
          return nil unless raw_value == expected
          [observed, {"partial" => true, "observed" => observed}]
        else
          [value, nil]
        end
      end
    end

    def strict_each_form_explode_list(remaining, separator, name, operator)
      fields = remaining.split(separator, -1)
      count = fields.take_while { |item| item.start_with?(name + "=") }.length
      1.upto(count) do |field_count|
        values = fields[0...field_count].map do |item|
          strict_decode_scalar(item[(name.length + 1)..-1], operator)
        end
        unless values.any?(&:nil?)
          yield values, strict_remaining_fields(remaining, fields, field_count,
                                               separator)
        end
      end
    end

    def strict_each_form_explode_map(remaining, separator, operator)
      fields = remaining.split(separator, -1)
      count = fields.take_while { |item| item.include?("=") }.length
      1.upto(count) do |field_count|
        pairs = strict_decode_map_fields(fields[0...field_count], operator, true)
        next unless pairs
        value = {}
        pairs.each { |key, val| value[key] = val }
        next if value.length != pairs.length
        yield value, strict_remaining_fields(remaining, fields, field_count,
                                            separator)
      end
    end

    def strict_remaining_fields(remaining, fields, field_count, separator)
      consumed = fields[0...field_count].map(&:length).inject(0, :+) +
        field_count - 1
      if field_count < fields.length
        remaining[(consumed + separator.length)..-1] || ""
      else
        ""
      end
    end

    def strict_add_value(mapping, prefixes, name, value, prefix)
      if mapping.key?(name)
        merged = strict_merge_values(
          mapping[name], prefixes[name], value, prefix, name, prefixes
        )
        return nil unless merged
        value, prefix = merged
      end
      new_mapping = mapping.dup
      new_mapping[name] = nil
      new_prefixes = prefixes.dup
      new_mapping[name] = value
      if prefix
        new_prefixes[name] = prefix
      else
        new_prefixes.delete(name)
      end
      [new_mapping, new_prefixes]
    end

    def strict_merge_mapping(mapping, prefixes, local_mapping, local_prefixes)
      result_mapping = mapping.dup
      result_prefixes = prefixes.dup
      local_mapping.each do |name, value|
        if result_mapping.key?(name)
          merged = strict_merge_values(
            result_mapping[name], result_prefixes[name],
            value, local_prefixes[name], name, result_prefixes
          )
          return nil unless merged
          value, prefix = merged
        else
          prefix = local_prefixes[name]
        end
        result_mapping[name] = value
        if prefix
          result_prefixes[name] = prefix
        else
          result_prefixes.delete(name)
        end
      end
      [result_mapping, result_prefixes]
    end

    def strict_merge_values(existing, existing_prefix, value, value_prefix,
                           name, prefixes)
      if existing.nil? && !existing_prefix && value.nil? && !value_prefix
        [nil, nil]
      elsif existing.nil? && existing_prefix && existing_prefix["pending"] &&
            !value_prefix
        [value, nil]
      elsif !existing_prefix && !value_prefix
        return nil unless existing == value
        [existing, nil]
      elsif String === existing && String === value
        merged_mapping, merged_prefix = strict_merge_prefix_values(
          existing, existing_prefix, value, value_prefix
        )
        return nil unless merged_mapping
        [merged_mapping, merged_prefix]
      else
        nil
      end
    end

    def strict_merge_prefix_values(existing, existing_prefix, value,
                                   value_prefix)
      if existing_prefix && value_prefix
        if existing_prefix["pending"]
          return [value, value_prefix]
        end
        if value_prefix["pending"]
          return [existing, existing_prefix]
        end
        if existing.length >= value.length
          return nil unless existing.start_with?(value)
          [existing, existing_prefix]
        else
          return nil unless value.start_with?(existing)
          [value, value_prefix]
        end
      elsif existing_prefix
        return [value, nil] if existing_prefix["pending"]
        return nil unless value.start_with?(existing)
        [value, nil]
      else
        return nil unless existing.start_with?(value)
        [existing, nil]
      end
    end

    def strict_prefixes_partial?(prefixes)
      !prefixes.empty?
    end

    ##
    # This class represents the data that is extracted when a Template
    # is matched against a URI.
    class MatchData
      ##
      # Creates a new MatchData object.
      # MatchData objects should never be instantiated directly.
      #
      # @param [Addressable::URI] uri
      #   The URI that the template was matched against.
      def initialize(uri, template, mapping)
        @uri = uri.dup.freeze
        @template = template
        @mapping = mapping.dup.freeze
      end

      ##
      # @return [Addressable::URI]
      #   The URI that the Template was matched against.
      attr_reader :uri

      ##
      # @return [Addressable::Template]
      #   The Template used for the match.
      attr_reader :template

      ##
      # @return [Hash]
      #   The mapping that resulted from the match.
      #   Note that this mapping does not include keys or values for
      #   variables that appear in the Template, but are not present
      #   in the URI.
      attr_reader :mapping

      ##
      # @return [Array]
      #   The list of variables that were present in the Template.
      #   Note that this list will include variables which do not appear
      #   in the mapping because they were not present in URI.
      def variables
        self.template.variables
      end
      alias_method :keys, :variables
      alias_method :names, :variables

      ##
      # @return [Array]
      #   The list of values that were captured by the Template.
      #   Note that this list will include nils for any variables which
      #   were in the Template, but did not appear in the URI.
      def values
        @values ||= self.variables.inject([]) do |accu, key|
          accu << self.mapping[key]
          accu
        end
      end
      alias_method :captures, :values

      ##
      # Accesses captured values by name or by index.
      #
      # @param [String, Symbol, Fixnum] key
      #   Capture index or name. Note that when accessing by with index
      #   of 0, the full URI will be returned. The intention is to mimic
      #   the ::MatchData#[] behavior.
      #
      # @param [#to_int, nil] len
      #   If provided, an array of values will be returned with the given
      #   parameter used as length.
      #
      # @return [Array, String, nil]
      #   The captured value corresponding to the index or name. If the
      #   value was not provided or the key is unknown, nil will be
      #   returned.
      #
      #   If the second parameter is provided, an array of that length will
      #   be returned instead.
      def [](key, len = nil)
        if len
          to_a[key, len]
        elsif String === key or Symbol === key
          mapping[key.to_s]
        else
          to_a[key]
        end
      end

      ##
      # @return [Array]
      #   Array with the matched URI as first element followed by the captured
      #   values.
      def to_a
        [to_s, *values]
      end

      ##
      # @return [String]
      #   The matched URI as String.
      def to_s
        uri.to_s
      end
      alias_method :string, :to_s

      # Returns multiple captured values at once.
      #
      # @param [String, Symbol, Fixnum] *indexes
      #   Indices of the captures to be returned
      #
      # @return [Array]
      #   Values corresponding to given indices.
      #
      # @see Addressable::Template::MatchData#[]
      def values_at(*indexes)
        indexes.map { |i| self[i] }
      end

      ##
      # Returns a <tt>String</tt> representation of the MatchData's state.
      #
      # @return [String] The MatchData's state, as a <tt>String</tt>.
      def inspect
        sprintf("#<%s:%#0x RESULT:%s>",
          self.class.to_s, self.object_id, self.mapping.inspect)
      end

      ##
      # Dummy method for code expecting a ::MatchData instance
      #
      # @return [String] An empty string.
      def pre_match
        ""
      end
      alias_method :post_match, :pre_match
    end

    ##
    # Creates a new <tt>Addressable::Template</tt> object.
    #
    # @param [#to_str] pattern The URI Template pattern.
    #
    # @return [Addressable::Template] The initialized Template object.
    def initialize(pattern)
      if !pattern.respond_to?(:to_str)
        raise TypeError, "Can't convert #{pattern.class} into String."
      end
      @pattern = pattern.to_str.dup.freeze
    end

    ##
    # Freeze URI, initializing instance variables.
    #
    # @return [Addressable::URI] The frozen URI object.
    def freeze
      self.variables
      self.variable_defaults
      self.named_captures
      super
    end

    ##
    # @return [String] The Template object's pattern.
    attr_reader :pattern

    ##
    # Returns a <tt>String</tt> representation of the Template object's state.
    #
    # @return [String] The Template object's state, as a <tt>String</tt>.
    def inspect
      sprintf("#<%s:%#0x PATTERN:%s>",
        self.class.to_s, self.object_id, self.pattern)
    end

    ##
    # Returns <code>true</code> if the Template objects are equal. This method
    # does NOT normalize either Template before doing the comparison.
    #
    # @param [Object] template The Template to compare.
    #
    # @return [TrueClass, FalseClass]
    #   <code>true</code> if the Templates are equivalent, <code>false</code>
    #   otherwise.
    def ==(template)
      return false unless template.kind_of?(Template)
      return self.pattern == template.pattern
    end

    ##
    # Addressable::Template makes no distinction between `==` and `eql?`.
    #
    # @see #==
    alias_method :eql?, :==

    ##
    # Extracts a mapping from the URI using a URI Template pattern.
    #
    # @param [Addressable::URI, #to_str] uri
    #   The URI to extract from.
    #
    # @param [#restore, #match] processor
    #   A template processor object may optionally be supplied.
    #
    #   The object should respond to either the <tt>restore</tt> or
    #   <tt>match</tt> messages or both. The <tt>restore</tt> method should
    #   take two parameters: `[String] name` and `[String] value`.
    #   The <tt>restore</tt> method should reverse any transformations that
    #   have been performed on the value to ensure a valid URI.
    #   The <tt>match</tt> method should take a single
    #   parameter: `[String] name`.  The <tt>match</tt> method should return
    #   a <tt>String</tt> containing a regular expression capture group for
    #   matching on that particular variable. The default value is `".*?"`.
    #   The <tt>match</tt> method has no effect on multivariate operator
    #   expansions.
    #
    # @return [Hash, NilClass]
    #   The <tt>Hash</tt> mapping that was extracted from the URI, or
    #   <tt>nil</tt> if the URI didn't match the template.
    #
    # @example
    #   class ExampleProcessor
    #     def self.restore(name, value)
    #       return value.gsub(/\+/, " ") if name == "query"
    #       return value
    #     end
    #
    #     def self.match(name)
    #       return ".*?" if name == "first"
    #       return ".*"
    #     end
    #   end
    #
    #   uri = Addressable::URI.parse(
    #     "http://example.com/search/an+example+search+query/"
    #   )
    #   Addressable::Template.new(
    #     "http://example.com/search/{query}/"
    #   ).extract(uri, ExampleProcessor)
    #   #=> {"query" => "an example search query"}
    #
    #   uri = Addressable::URI.parse("http://example.com/a/b/c/")
    #   Addressable::Template.new(
    #     "http://example.com/{first}/{second}/"
    #   ).extract(uri, ExampleProcessor)
    #   #=> {"first" => "a", "second" => "b/c"}
    #
    #   uri = Addressable::URI.parse("http://example.com/a/b/c/")
    #   Addressable::Template.new(
    #     "http://example.com/{first}/{-list|/|second}/"
    #   ).extract(uri)
    #   #=> {"first" => "a", "second" => ["b", "c"]}
    def extract(uri, processor=nil)
      match_data = self.match(uri, processor)
      return (match_data ? match_data.mapping : nil)
    end

    ##
    # Strictly extracts all mappings that expand back to the URI.
    #
    # Unlike {#extract}, this method does not silently choose one ambiguous
    # value. Variable types must be declared as <tt>:scalar</tt>,
    # <tt>:list</tt>, or <tt>:map</tt>.
    #
    # @param [Addressable::URI, #to_str] uri The URI to extract from.
    # @param [Hash] types Variable names to <tt>:scalar</tt>, <tt>:list</tt>,
    #   or <tt>:map</tt>.
    # @param [Integer] max_candidates Maximum number of candidates to return.
    #
    # @return [Addressable::Template::StrictMatchData] The extraction result.
    def strict_extract(uri, types={}, max_candidates=100)
      self.strict_match(uri, types, max_candidates)
    end

    ##
    # Strictly matches a URI while retaining ambiguous reverse matches.
    #
    # Each returned candidate is accepted only when expanding this template
    # with that candidate reproduces the original URI. When the candidate limit
    # is exceeded, the result retains only the first candidates and reports
    # <tt>:truncated</tt>.
    #
    # A prefix modifier such as <tt>{x:2}</tt> cannot always recover the full
    # value. In that case the result reports <tt>:incomplete</tt>.
    #
    # @param [Addressable::URI, #to_str] uri The URI to match.
    # @param [Hash] types Variable names to <tt>:scalar</tt>, <tt>:list</tt>,
    #   or <tt>:map</tt>.
    # @param [Integer] max_candidates Maximum number of candidates to return.
    #
    # @return [Addressable::Template::StrictMatchData] The match result.
    #
    # @example
    #   result = Addressable::Template.new("{+x}{+y}").strict_match(
    #     "a/b", "x" => :scalar, "y" => :scalar
    #   )
    #   result.status #=> :multiple
    #   result.candidates.length #=> 6
    def strict_match(uri, types={}, max_candidates=100)
      uri = Addressable::URI.parse(uri) unless uri.is_a?(Addressable::URI)
      strict_types = strict_variable_types(types)
      limit = strict_candidate_limit(max_candidates)

      candidates = []
      incomplete = false
      truncated = false
      seen = {}
      partial_seen = {}
      context = false

      strict_search_tokens(pattern, uri.to_str, 0, 0, strict_types, {}, {},
                           context) do |mapping, prefixes, partial|
        key = Marshal.dump(mapping)
        if partial
          key = Marshal.dump([mapping, prefixes])
          incomplete = true unless partial_seen.key?(key)
          partial_seen[key] = true
          next
        end
        next if context
        next if seen.key?(key)
        seen[key] = true
        expanded = self.expand(mapping).to_str rescue nil
        next unless expanded == uri.to_str
        candidates << mapping
        if candidates.length > limit
          truncated = true
          context = true
        end
      end

      Addressable::Template::StrictMatchData.new(
        uri, self, strict_types, truncated ? candidates[0...limit] : candidates,
        incomplete, truncated, limit
      )
    end

    ##
    # Extracts match data from the URI using a URI Template pattern.
    #
    # @param [Addressable::URI, #to_str] uri
    #   The URI to extract from.
    #
    # @param [#restore, #match] processor
    #   A template processor object may optionally be supplied.
    #
    #   The object should respond to either the <tt>restore</tt> or
    #   <tt>match</tt> messages or both. The <tt>restore</tt> method should
    #   take two parameters: `[String] name` and `[String] value`.
    #   The <tt>restore</tt> method should reverse any transformations that
    #   have been performed on the value to ensure a valid URI.
    #   The <tt>match</tt> method should take a single
    #   parameter: `[String] name`. The <tt>match</tt> method should return
    #   a <tt>String</tt> containing a regular expression capture group for
    #   matching on that particular variable. The default value is `".*?"`.
    #   The <tt>match</tt> method has no effect on multivariate operator
    #   expansions.
    #
    # @return [Hash, NilClass]
    #   The <tt>Hash</tt> mapping that was extracted from the URI, or
    #   <tt>nil</tt> if the URI didn't match the template.
    #
    # @example
    #   class ExampleProcessor
    #     def self.restore(name, value)
    #       return value.gsub(/\+/, " ") if name == "query"
    #       return value
    #     end
    #
    #     def self.match(name)
    #       return ".*?" if name == "first"
    #       return ".*"
    #     end
    #   end
    #
    #   uri = Addressable::URI.parse(
    #     "http://example.com/search/an+example+search+query/"
    #   )
    #   match = Addressable::Template.new(
    #     "http://example.com/search/{query}/"
    #   ).match(uri, ExampleProcessor)
    #   match.variables
    #   #=> ["query"]
    #   match.captures
    #   #=> ["an example search query"]
    #
    #   uri = Addressable::URI.parse("http://example.com/a/b/c/")
    #   match = Addressable::Template.new(
    #     "http://example.com/{first}/{+second}/"
    #   ).match(uri, ExampleProcessor)
    #   match.variables
    #   #=> ["first", "second"]
    #   match.captures
    #   #=> ["a", "b/c"]
    #
    #   uri = Addressable::URI.parse("http://example.com/a/b/c/")
    #   match = Addressable::Template.new(
    #     "http://example.com/{first}{/second*}/"
    #   ).match(uri)
    #   match.variables
    #   #=> ["first", "second"]
    #   match.captures
    #   #=> ["a", ["b", "c"]]
    def match(uri, processor=nil)
      uri = Addressable::URI.parse(uri) unless uri.is_a?(Addressable::URI)
      mapping = {}

      # First, we need to process the pattern, and extract the values.
      expansions, expansion_regexp =
        parse_template_pattern(pattern, processor)

      return nil unless uri.to_str.match(expansion_regexp)
      unparsed_values = uri.to_str.scan(expansion_regexp).flatten

      if uri.to_str == pattern
        return Addressable::Template::MatchData.new(uri, self, mapping)
      elsif expansions.size > 0
        index = 0
        expansions.each do |expansion|
          _, operator, varlist = *expansion.match(EXPRESSION)
          varlist.split(',').each do |varspec|
            _, name, modifier = *varspec.match(VARSPEC)
            mapping[name] ||= nil
            case operator
            when nil, '+', '#', '/', '.'
              unparsed_value = unparsed_values[index]
              name = varspec[VARSPEC, 1]
              value = unparsed_value
              value = value.split(JOINERS[operator]) if value && modifier == '*'
            when ';', '?', '&'
              if modifier == '*'
                if unparsed_values[index]
                  value = unparsed_values[index].split(JOINERS[operator])
                  value = value.inject({}) do |acc, v|
                    key, val = v.split('=')
                    val = "" if val.nil?
                    acc[key] = val
                    acc
                  end
                end
              else
                if (unparsed_values[index])
                  name, value = unparsed_values[index].split('=')
                  value = "" if value.nil?
                end
              end
            end
            if processor != nil && processor.respond_to?(:restore)
              value = processor.restore(name, value)
            end
            if processor == nil
              if value.is_a?(Hash)
                value = value.inject({}){|acc, (k, v)|
                  acc[Addressable::URI.unencode_component(k)] =
                    Addressable::URI.unencode_component(v)
                  acc
                }
              elsif value.is_a?(Array)
                value = value.map{|v| Addressable::URI.unencode_component(v) }
              else
                value = Addressable::URI.unencode_component(value)
              end
            end
            if !mapping.has_key?(name) || mapping[name].nil?
              # Doesn't exist, set to value (even if value is nil)
              mapping[name] = value
            end
            index = index + 1
          end
        end
        return Addressable::Template::MatchData.new(uri, self, mapping)
      else
        return nil
      end
    end

    ##
    # Expands a URI template into another URI template.
    #
    # @param [Hash] mapping The mapping that corresponds to the pattern.
    # @param [#validate, #transform] processor
    #   An optional processor object may be supplied.
    # @param [Boolean] normalize_values
    #   Optional flag to enable/disable unicode normalization. Default: true
    #
    # The object should respond to either the <tt>validate</tt> or
    # <tt>transform</tt> messages or both. Both the <tt>validate</tt> and
    # <tt>transform</tt> methods should take two parameters: <tt>name</tt> and
    # <tt>value</tt>. The <tt>validate</tt> method should return <tt>true</tt>
    # or <tt>false</tt>; <tt>true</tt> if the value of the variable is valid,
    # <tt>false</tt> otherwise. An <tt>InvalidTemplateValueError</tt>
    # exception will be raised if the value is invalid. The <tt>transform</tt>
    # method should return the transformed variable value as a <tt>String</tt>.
    # If a <tt>transform</tt> method is used, the value will not be percent
    # encoded automatically. Unicode normalization will be performed both
    # before and after sending the value to the transform method.
    #
    # @return [Addressable::Template] The partially expanded URI template.
    #
    # @example
    #   Addressable::Template.new(
    #     "http://example.com/{one}/{two}/"
    #   ).partial_expand({"one" => "1"}).pattern
    #   #=> "http://example.com/1/{two}/"
    #
    #   Addressable::Template.new(
    #     "http://example.com/{?one,two}/"
    #   ).partial_expand({"one" => "1"}).pattern
    #   #=> "http://example.com/?one=1{&two}/"
    #
    #   Addressable::Template.new(
    #     "http://example.com/{?one,two,three}/"
    #   ).partial_expand({"one" => "1", "three" => 3}).pattern
    #   #=> "http://example.com/?one=1{&two}&three=3"
    def partial_expand(mapping, processor=nil, normalize_values=true)
      result = self.pattern.dup
      mapping = normalize_keys(mapping)
      result.gsub!( EXPRESSION ) do |capture|
        transform_partial_capture(mapping, capture, processor, normalize_values)
      end
      return Addressable::Template.new(result)
    end

    ##
    # Expands a URI template into a full URI.
    #
    # @param [Hash] mapping The mapping that corresponds to the pattern.
    # @param [#validate, #transform] processor
    #   An optional processor object may be supplied.
    # @param [Boolean] normalize_values
    #   Optional flag to enable/disable unicode normalization. Default: true
    #
    # The object should respond to either the <tt>validate</tt> or
    # <tt>transform</tt> messages or both. Both the <tt>validate</tt> and
    # <tt>transform</tt> methods should take two parameters: <tt>name</tt> and
    # <tt>value</tt>. The <tt>validate</tt> method should return <tt>true</tt>
    # or <tt>false</tt>; <tt>true</tt> if the value of the variable is valid,
    # <tt>false</tt> otherwise. An <tt>InvalidTemplateValueError</tt>
    # exception will be raised if the value is invalid. The <tt>transform</tt>
    # method should return the transformed variable value as a <tt>String</tt>.
    # If a <tt>transform</tt> method is used, the value will not be percent
    # encoded automatically. Unicode normalization will be performed both
    # before and after sending the value to the transform method.
    #
    # @return [Addressable::URI] The expanded URI template.
    #
    # @example
    #   class ExampleProcessor
    #     def self.validate(name, value)
    #       return !!(value =~ /^[\w ]+$/) if name == "query"
    #       return true
    #     end
    #
    #     def self.transform(name, value)
    #       return value.gsub(/ /, "+") if name == "query"
    #       return value
    #     end
    #   end
    #
    #   Addressable::Template.new(
    #     "http://example.com/search/{query}/"
    #   ).expand(
    #     {"query" => "an example search query"},
    #     ExampleProcessor
    #   ).to_str
    #   #=> "http://example.com/search/an+example+search+query/"
    #
    #   Addressable::Template.new(
    #     "http://example.com/search/{query}/"
    #   ).expand(
    #     {"query" => "an example search query"}
    #   ).to_str
    #   #=> "http://example.com/search/an%20example%20search%20query/"
    #
    #   Addressable::Template.new(
    #     "http://example.com/search/{query}/"
    #   ).expand(
    #     {"query" => "bogus!"},
    #     ExampleProcessor
    #   ).to_str
    #   #=> Addressable::Template::InvalidTemplateValueError
    def expand(mapping, processor=nil, normalize_values=true)
      result = self.pattern.dup
      mapping = normalize_keys(mapping)
      result.gsub!( EXPRESSION ) do |capture|
        transform_capture(mapping, capture, processor, normalize_values)
      end
      return Addressable::URI.parse(result)
    end

    ##
    # Returns an Array of variables used within the template pattern.
    # The variables are listed in the Array in the order they appear within
    # the pattern.  Multiple occurrences of a variable within a pattern are
    # not represented in this Array.
    #
    # @return [Array] The variables present in the template's pattern.
    def variables
      @variables ||= ordered_variable_defaults.map { |var, val| var }.uniq
    end
    alias_method :keys, :variables
    alias_method :names, :variables

    ##
    # Returns a mapping of variables to their default values specified
    # in the template. Variables without defaults are not returned.
    #
    # @return [Hash] Mapping of template variables to their defaults
    def variable_defaults
      @variable_defaults ||=
        Hash[*ordered_variable_defaults.reject { |k, v| v.nil? }.flatten]
    end

    ##
    # Coerces a template into a `Regexp` object. This regular expression will
    # behave very similarly to the actual template, and should match the same
    # URI values, but it cannot fully handle, for example, values that would
    # extract to an `Array`.
    #
    # @return [Regexp] A regular expression which should match the template.
    def to_regexp
      _, source = parse_template_pattern(pattern)
      Regexp.new(source)
    end

    ##
    # Returns the source of the coerced `Regexp`.
    #
    # @return [String] The source of the `Regexp` given by {#to_regexp}.
    #
    # @api private
    def source
      self.to_regexp.source
    end

    ##
    # Returns the named captures of the coerced `Regexp`.
    #
    # @return [Hash] The named captures of the `Regexp` given by {#to_regexp}.
    #
    # @api private
    def named_captures
      self.to_regexp.named_captures
    end

  private
    def ordered_variable_defaults
      @ordered_variable_defaults ||= begin
        expansions, _ = parse_template_pattern(pattern)
        expansions.flat_map do |capture|
          _, _, varlist = *capture.match(EXPRESSION)
          varlist.split(',').map do |varspec|
            varspec[VARSPEC, 1]
          end
        end
      end
    end

    def strict_variable_types(types)
      result = {}
      types.each do |name, type|
        normalized_name = name.to_s
        normalized_type = case type.to_s
        when "scalar", "string", "str" then :scalar
        when "list", "array" then :list
        when "map", "hash" then :map
        else
          raise ArgumentError,
            "Unknown variable type #{type.inspect} for #{name.inspect}."
        end
        unless self.variables.include?(normalized_name)
          raise ArgumentError,
            "Unknown variable #{normalized_name.inspect}."
        end
        result[normalized_name] = normalized_type
      end
      self.variables.each do |name|
        result[name] ||= :scalar
      end
      result
    end

    def strict_candidate_limit(limit)
      unless limit.is_a?(Integer) && limit > 0
        raise ArgumentError, "max_candidates must be a positive Integer."
      end
      limit
    end

    def strict_tokens(pattern)
      tokens = []
      position = 0
      while (match = EXPRESSION.match(pattern, position))
        if match.begin(0) > position
          tokens << [:literal, pattern[position...match.begin(0)]]
        end
        tokens << [:expression, match[0]]
        position = match.end(0)
      end
      if position < pattern.length
        tokens << [:literal, pattern[position..-1]]
      end
      tokens
    end

    def strict_expression_metadata(expression, types)
      _, operator, varlist = *expression.match(EXPRESSION)
      vars = varlist.split(",").map do |varspec|
        _, name, modifier = *varspec.match(VARSPEC)
        prefix = nil
        if modifier && modifier.start_with?(":")
          prefix = modifier[1..-1].to_i
        end
        {
          "name" => name,
          "type" => types.fetch(name),
          "explode" => modifier == "*",
          "prefix" => prefix
        }
      end
      {"operator" => operator, "vars" => vars}
    end

    def strict_search_tokens(pattern, uri, token_index, uri_position, types,
                             mapping, prefixes, context, &block)
      return if context
      tokens = strict_tokens(pattern)

      if token_index >= tokens.length
        return unless uri_position == uri.length
        partial = strict_prefixes_partial?(prefixes)
        if partial
          complete = self.variables.each_with_object({}) do |name, acc|
            acc[name] = mapping[name] if mapping.key?(name)
          end
          block.call(complete, prefixes, true)
          return
        end
        complete = self.variables.each_with_object({}) do |name, acc|
          acc[name] = mapping.fetch(name, nil)
        end
        block.call(complete, prefixes, false)
        return
      end

      kind, value = tokens[token_index]
      if kind == :literal
        return unless uri[uri_position..-1].start_with?(value)
        strict_search_tokens(
              pattern, uri, token_index + 1, uri_position + value.length, types,
              mapping, prefixes, context, &block
        )
      else
        metadata = strict_expression_metadata(value, types)
        last_expression = token_index == tokens.length - 1
        strict_expression_contributions(uri, uri_position, metadata,
                                        last_expression) do |raw, next_position|
          strict_parse_expression(raw, metadata, context) do |local_mapping,
                                                                local_prefixes,
                                                                local_partial|
            next if local_partial && local_prefixes.empty?
            merged = strict_merge_mapping(mapping, prefixes,
                                         local_mapping, local_prefixes)
            next unless merged
            merged_mapping, merged_prefixes = merged
            metadata["vars"].each do |variable|
              name = variable["name"]
              next unless variable["type"] == :scalar && variable["prefix"]
              next if local_mapping.key?(name)
              next if merged_prefixes.key?(name)
              merged_prefixes[name] = {
                "partial" => true,
                "pending" => true,
                "prefix" => variable["prefix"]
              }
            end
            strict_search_tokens(
              pattern, uri, token_index + 1, next_position, types,
              merged_mapping, merged_prefixes,
              context, &block
            )
          end
        end
      end
    end

    def strict_expression_contributions(uri, position, metadata, consume_all)
      operator = metadata["operator"]
      leader = LEADERS.fetch(operator, "")
      yield "", position if leader.empty?
      if !leader.empty? && uri[position..-1].start_with?(leader)
        body_start = position + leader.length
        stops = consume_all ? [uri.length] : body_start.upto(uri.length).to_a
        stops.each do |stop|
          yield uri[body_start...stop], stop
        end
      elsif leader.empty?
        stops = consume_all ? [uri.length] : (position + 1).upto(uri.length).to_a
        stops.each do |stop|
          yield uri[position...stop], stop
        end
      end
    end

    def strict_parse_expression(raw, metadata, context, &block)
      operator = metadata["operator"]
      vars = metadata["vars"]
      if %w(; ? &).include?(operator)
        strict_parse_form(raw, operator, vars, 0, {}, {}, false, context, &block)
      else
        strict_parse_nonform(raw, operator, vars, 0, {}, {}, false, context, &block)
      end
    end

    def strict_allowed_scalar?(raw, operator)
      pattern = if %w(+ #).include?(operator)
        "\\A(?:#{RESERVED})*\\z"
      else
        "\\A(?:#{UNRESERVED})*\\z"
      end
      !!(raw =~ Regexp.new(pattern))
    end

    def strict_decode_scalar(raw, operator)
      return nil unless strict_allowed_scalar?(raw, operator)
      Addressable::URI.unencode_component(raw)
    end

    def strict_encode_scalar(value, operator)
      character_class = if %w(+ #).include?(operator)
        Addressable::URI::CharacterClassesRegexps::RESERVED_AND_UNRESERVED
      else
        Addressable::URI::CharacterClassesRegexps::UNRESERVED
      end
      Addressable::URI.encode_component(value, character_class)
    end

    def strict_each_scalar(raw, operator, variable, prior, context)
      prefix = variable["prefix"]
      separator = JOINERS.fetch(operator, ",")
      start = 0
      if prior
        return unless raw.start_with?(separator)
        start = separator.length
      end
      remaining = raw[start..-1] || ""
      (0..remaining.length).each do |length|
        return if context
        chunk = remaining[0...length]
        decoded = strict_decode_scalar(chunk, operator)
        next if decoded.nil?
        next_raw = raw[(start + length)..-1] || ""
        if prefix
          observed = decoded[0...prefix]
          expected = strict_encode_scalar(observed, operator)
          next unless chunk == expected
          if prefix == 0
            yield "", next_raw, {
              "partial" => true,
              "observed" => ""
            }
          else
            yield observed, next_raw, {
              "partial" => true,
              "observed" => observed
            }
          end
        else
          yield decoded, next_raw, nil
        end
      end
    end

    def strict_parse_nonform(raw, operator, vars, index, mapping, prefixes, prior,
                            context, &block)
      if index >= vars.length
        yield mapping, prefixes, strict_prefixes_partial?(prefixes) if raw.empty?
        return
      end

      variable = vars[index]
      name = variable["name"]
      type = variable["type"]

      strict_parse_nonform(
        raw, operator, vars, index + 1, mapping, prefixes, prior, context, &block
      )

      case type
      when :scalar
        strict_each_scalar(raw, operator, variable, prior, context) do |value, next_raw, prefix|
          merged = strict_add_value(mapping, prefixes, name, value, prefix)
          next unless merged
          strict_parse_nonform(
            next_raw, operator, vars, index + 1, merged[0], merged[1], true,
            context, &block
          )
        end
      when :list
        last_variable = index == vars.length - 1
        strict_each_nonform_list(raw, operator, variable, prior, context,
                                 last_variable) do |value, next_raw, prefix|
          merged = strict_add_value(mapping, prefixes, name, value, prefix)
          next unless merged
          strict_parse_nonform(
            next_raw, operator, vars, index + 1, merged[0], merged[1], true,
            context, &block
          )
        end
      when :map
        empty_merged = strict_add_value(mapping, prefixes, name, Hash.new, nil)
        if empty_merged
          strict_parse_nonform(
            raw, operator, vars, index + 1, empty_merged[0], empty_merged[1],
            prior, context, &block
          )
        end
        last_variable = index == vars.length - 1
        strict_each_nonform_map(raw, operator, variable, prior, context,
                                last_variable) do |value, next_raw, prefix|
          merged = strict_add_value(mapping, prefixes, name, value, prefix)
          next unless merged
          strict_parse_nonform(
            next_raw, operator, vars, index + 1, merged[0], merged[1], !value.empty?,
            context, &block
          )
        end
      end
    end


    ##
    # Loops through each capture and expands any values available in mapping
    #
    # @param [Hash] mapping
    #   Set of keys to expand
    # @param [String] capture
    #   The expression to expand
    # @param [#validate, #transform] processor
    #   An optional processor object may be supplied.
    # @param [Boolean] normalize_values
    #   Optional flag to enable/disable unicode normalization. Default: true
    #
    # The object should respond to either the <tt>validate</tt> or
    # <tt>transform</tt> messages or both. Both the <tt>validate</tt> and
    # <tt>transform</tt> methods should take two parameters: <tt>name</tt> and
    # <tt>value</tt>. The <tt>validate</tt> method should return <tt>true</tt>
    # or <tt>false</tt>; <tt>true</tt> if the value of the variable is valid,
    # <tt>false</tt> otherwise. An <tt>InvalidTemplateValueError</tt> exception
    # will be raised if the value is invalid. The <tt>transform</tt> method
    # should return the transformed variable value as a <tt>String</tt>. If a
    # <tt>transform</tt> method is used, the value will not be percent encoded
    # automatically. Unicode normalization will be performed both before and
    # after sending the value to the transform method.
    #
    # @return [String] The expanded expression
    def transform_partial_capture(mapping, capture, processor = nil,
                                  normalize_values = true)
      _, operator, varlist = *capture.match(EXPRESSION)

      vars = varlist.split(",")

      if operator == "?"
        # partial expansion of form style query variables sometimes requires a
        # slight reordering of the variables to produce a valid url.
        first_to_expand = vars.find { |varspec|
          _, name, _ =  *varspec.match(VARSPEC)
          mapping.key?(name) && !mapping[name].nil?
        }

        vars = [first_to_expand] + vars.reject {|varspec| varspec == first_to_expand}  if first_to_expand
      end

      vars.
        inject("".dup) do |acc, varspec|
          _, name, _ =  *varspec.match(VARSPEC)
          next_val = if mapping.key? name
                       transform_capture(mapping, "{#{operator}#{varspec}}",
                                         processor, normalize_values)
                     else
                       "{#{operator}#{varspec}}"
                     end
          # If we've already expanded at least one '?' operator with non-empty
          # value, change to '&'
          operator = "&" if (operator == "?") && (next_val != "")
          acc << next_val
      end
    end

    ##
    # Transforms a mapped value so that values can be substituted into the
    # template.
    #
    # @param [Hash] mapping The mapping to replace captures
    # @param [String] capture
    #   The expression to replace
    # @param [#validate, #transform] processor
    #   An optional processor object may be supplied.
    # @param [Boolean] normalize_values
    #   Optional flag to enable/disable unicode normalization. Default: true
    #
    #
    # The object should respond to either the <tt>validate</tt> or
    # <tt>transform</tt> messages or both. Both the <tt>validate</tt> and
    # <tt>transform</tt> methods should take two parameters: <tt>name</tt> and
    # <tt>value</tt>. The <tt>validate</tt> method should return <tt>true</tt>
    # or <tt>false</tt>; <tt>true</tt> if the value of the variable is valid,
    # <tt>false</tt> otherwise. An <tt>InvalidTemplateValueError</tt> exception
    # will be raised if the value is invalid. The <tt>transform</tt> method
    # should return the transformed variable value as a <tt>String</tt>. If a
    # <tt>transform</tt> method is used, the value will not be percent encoded
    # automatically. Unicode normalization will be performed both before and
    # after sending the value to the transform method.
    #
    # @return [String] The expanded expression
    def transform_capture(mapping, capture, processor=nil,
                          normalize_values=true)
      _, operator, varlist = *capture.match(EXPRESSION)
      return_value = varlist.split(',').inject([]) do |acc, varspec|
        _, name, modifier = *varspec.match(VARSPEC)
        value = mapping[name]
        unless value == nil || value == {}
          allow_reserved = %w(+ #).include?(operator)
          # Common primitives where the .to_s output is well-defined
          if Numeric === value || Symbol === value ||
              value == true || value == false
            value = value.to_s
          end
          length = modifier.gsub(':', '').to_i if modifier =~ /^:\d+/

          unless (Hash === value) ||
            value.respond_to?(:to_ary) || value.respond_to?(:to_str)
            raise TypeError,
              "Can't convert #{value.class} into String or Array."
          end

          value = normalize_value(value) if normalize_values

          if processor == nil || !processor.respond_to?(:transform)
            # Handle percent escaping
            if allow_reserved
              encode_map =
                Addressable::URI::CharacterClasses::RESERVED +
                Addressable::URI::CharacterClasses::UNRESERVED
            else
              encode_map = Addressable::URI::CharacterClasses::UNRESERVED
            end
            if value.kind_of?(Array)
              transformed_value = value.map do |val|
                if length
                  Addressable::URI.encode_component(val[0...length], encode_map)
                else
                  Addressable::URI.encode_component(val, encode_map)
                end
              end
              unless modifier == "*"
                transformed_value = transformed_value.join(',')
              end
            elsif value.kind_of?(Hash)
              transformed_value = value.map do |key, val|
                if modifier == "*"
                  "#{
                    Addressable::URI.encode_component( key, encode_map)
                  }=#{
                    Addressable::URI.encode_component( val, encode_map)
                  }"
                else
                  "#{
                    Addressable::URI.encode_component( key, encode_map)
                  },#{
                    Addressable::URI.encode_component( val, encode_map)
                  }"
                end
              end
              unless modifier == "*"
                transformed_value = transformed_value.join(',')
              end
            else
              if length
                transformed_value = Addressable::URI.encode_component(
                  value[0...length], encode_map)
              else
                transformed_value = Addressable::URI.encode_component(
                  value, encode_map)
              end
            end
          end

          # Process, if we've got a processor
          if processor != nil
            if processor.respond_to?(:validate)
              if !processor.validate(name, value)
                display_value = value.kind_of?(Array) ? value.inspect : value
                raise InvalidTemplateValueError,
                  "#{name}=#{display_value} is an invalid template value."
              end
            end
            if processor.respond_to?(:transform)
              transformed_value = processor.transform(name, value)
              if normalize_values
                transformed_value = normalize_value(transformed_value)
              end
            end
          end
          acc << [name, transformed_value]
        end
        acc
      end
      return "" if return_value.empty?
      join_values(operator, return_value)
    end

    ##
    # Takes a set of values, and joins them together based on the
    # operator.
    #
    # @param [String, Nil] operator One of the operators from the set
    #   (?,&,+,#,;,/,.), or nil if there wasn't one.
    # @param [Array] return_value
    #   The set of return values (as [variable_name, value] tuples) that will
    #   be joined together.
    #
    # @return [String] The transformed mapped value
    def join_values(operator, return_value)
      leader = LEADERS.fetch(operator, '')
      joiner = JOINERS.fetch(operator, ',')
      case operator
      when '&', '?'
        leader + return_value.map{|k,v|
          if v.is_a?(Array) && v.first =~ /=/
            v.join(joiner)
          elsif v.is_a?(Array)
            v.map{|inner_value| "#{k}=#{inner_value}"}.join(joiner)
          else
            "#{k}=#{v}"
          end
        }.join(joiner)
      when ';'
        return_value.map{|k,v|
          if v.is_a?(Array) && v.first =~ /=/
            ';' + v.join(";")
          elsif v.is_a?(Array)
            ';' + v.map{|inner_value| "#{k}=#{inner_value}"}.join(";")
          else
            v && v != '' ?  ";#{k}=#{v}" : ";#{k}"
          end
        }.join
      else
        leader + return_value.map{|k,v| v}.join(joiner)
      end
    end

    ##
    # Takes a set of values, and joins them together based on the
    # operator.
    #
    # @param [Hash, Array, String] value
    #   Normalizes unicode keys and values with String#unicode_normalize (NFC)
    #
    # @return [Hash, Array, String] The normalized values
    def normalize_value(value)
      # Handle unicode normalization
      if value.respond_to?(:to_ary)
        value.to_ary.map! { |val| normalize_value(val) }
      elsif value.kind_of?(Hash)
        value = value.inject({}) { |acc, (k, v)|
          acc[normalize_value(k)] = normalize_value(v)
          acc
        }
      else
        value = value.to_s if !value.kind_of?(String)
        if value.encoding != Encoding::UTF_8
          value = value.dup.force_encoding(Encoding::UTF_8)
        end
        value = value.unicode_normalize(:nfc)
      end
      value
    end

    ##
    # Generates a hash with string keys
    #
    # @param [Hash] mapping A mapping hash to normalize
    #
    # @return [Hash]
    #   A hash with stringified keys
    def normalize_keys(mapping)
      return mapping.inject({}) do |accu, pair|
        name, value = pair
        if Symbol === name
          name = name.to_s
        elsif name.respond_to?(:to_str)
          name = name.to_str
        else
          raise TypeError,
            "Can't convert #{name.class} into String."
        end
        accu[name] = value
        accu
      end
    end

    ##
    # Generates the <tt>Regexp</tt> that parses a template pattern. Memoizes the
    # value if template processor not set (processors may not be deterministic)
    #
    # @param [String] pattern The URI template pattern.
    # @param [#match] processor The template processor to use.
    #
    # @return [Array, Regexp]
    #   An array of expansion variables nad a regular expression which may be
    #   used to parse a template pattern
    def parse_template_pattern(pattern, processor = nil)
      if processor.nil? && pattern == @pattern
        @cached_template_parse ||=
          parse_new_template_pattern(pattern, processor)
      else
        parse_new_template_pattern(pattern, processor)
      end
    end

    ##
    # Generates the <tt>Regexp</tt> that parses a template pattern.
    #
    # @param [String] pattern The URI template pattern.
    # @param [#match] processor The template processor to use.
    #
    # @return [Array, Regexp]
    #   An array of expansion variables nad a regular expression which may be
    #   used to parse a template pattern
    def parse_new_template_pattern(pattern, processor = nil)
      # Escape the pattern. The two gsubs restore the escaped curly braces
      # back to their original form. Basically, escape everything that isn't
      # within an expansion.
      escaped_pattern = Regexp.escape(
        pattern
      ).gsub(/\\\{(.*?)\\\}/) do |escaped|
        escaped.gsub(/\\(.)/, "\\1")
      end

      expansions = []

      # Create a regular expression that captures the values of the
      # variables in the URI.
      regexp_string = escaped_pattern.gsub( EXPRESSION ) do |expansion|
        post_expansion = $'

        expansions << expansion
        _, operator, varlist = *expansion.match(EXPRESSION)
        leader = Regexp.escape(LEADERS.fetch(operator, ''))
        joiner = Regexp.escape(JOINERS.fetch(operator, ','))
        varspecs = varlist.split(',')
        # For multi-variable +/# expressions with no explode modifier, use atomic
        # joiners and remove outer optionality on non-last variables to prevent
        # O(2^k) backtracking from the combination of optional variables and
        # optional separators.
        has_explode = varspecs.any? { |vs| vs.match(VARSPEC)&.captures&.last == '*' }
        atomic_multi = varspecs.size > 1 &&
                       (operator == '+' || operator == '#') &&
                       !has_explode
        joiner_sep = atomic_multi ? "(?>#{joiner}?)" : "#{joiner}?"
        combined = varspecs.map do |varspec|
          _, name, modifier = *varspec.match(VARSPEC)

          result = processor && processor.respond_to?(:match) ? processor.match(name) : nil
          if result
            "(?<#{name}>#{ result })"
          else
            group = case operator
            when '+'
              "#{ RESERVED }*?"
            when '#'
              "#{ RESERVED }*?"
            when '/'
              "#{ UNRESERVED }*?"
            when '.'
              "#{ UNRESERVED.gsub('\.', '') }*?"
            when ';'
              "#{ UNRESERVED }*=?#{ UNRESERVED }*?"
            when '?'
              "#{ UNRESERVED }*=#{ UNRESERVED }*?"
            when '&'
              "#{ UNRESERVED }*=#{ UNRESERVED }*?"
            else
              "#{ UNRESERVED }*?"
            end
            if modifier == '*'
              seg = case operator
                    when '+', '#' then "(?>#{RESERVED_NO_COMMA}*)"
                    else group
                    end
              joiner_pattern = operator.nil? ? joiner : "#{joiner}?"
              "(?<#{name}>#{seg}(?:#{joiner_pattern}#{seg})*)?"
            elsif atomic_multi && varspec != varspecs.last
              "(?<#{name}>(?>#{RESERVED_NO_COMMA}*))"
            elsif operator == '+' && varspecs.size == 1 &&
                  post_expansion.start_with?('{+')
              "(?<#{name}>(?>#{RESERVED}*))?"
            else
              "(?<#{name}>#{group})?"
            end
          end
        end.join(joiner_sep)
        "(?:|#{leader}#{combined})"
      end

      # Ensure that the regular expression matches the whole URI.
      regexp_string = "\\A#{regexp_string}\\z"
      return expansions, Regexp.new(regexp_string)
    end

    private :strict_variable_types, :strict_candidate_limit, :strict_tokens,
      :strict_expression_metadata, :strict_search_tokens,
      :strict_expression_contributions, :strict_parse_expression,
      :strict_allowed_scalar?, :strict_decode_scalar, :strict_encode_scalar,
      :strict_each_scalar, :strict_parse_nonform, :strict_each_nonform_list,
      :strict_each_nonform_map, :strict_split_positions,
      :strict_enumerate_partitions, :strict_decode_map_fields,
      :strict_parse_form,
      :strict_field_boundary, :strict_form_scalar,
      :strict_each_form_explode_list, :strict_each_form_explode_map,
      :strict_add_value, :strict_merge_mapping, :strict_merge_values,
      :strict_merge_prefix_values, :strict_prefixes_partial?
  end
end
