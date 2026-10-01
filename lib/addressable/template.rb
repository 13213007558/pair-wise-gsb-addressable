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


require "set"
require "addressable/version"
require "addressable/uri"

module Addressable
  ##
  # This is an implementation of a URI template based on
  # RFC 6570 (http://tools.ietf.org/html/rfc6570).
  class Template
    # Constants used throughout the template code.
    STRICT_ENUMERATION_LIMIT = 1024
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
    # Raised if an invalid variable type is supplied to strict extraction.
    class InvalidTemplateVariableTypeError < ArgumentError
    end

    ##
    # Raised if an invalid template operator is used in a pattern.
    class TemplateOperatorAbortedError < StandardError
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
    # This class represents the result of strict reverse matching.
    class StrictMatchData
      # Valid statuses for a strict match.
      STATUSES = [:unique, :multiple, :no_match, :truncated].freeze

      ##
      # Creates a new StrictMatchData object.
      # StrictMatchData objects should never be instantiated directly.
      #
      # @param [Addressable::URI] uri
      #   The URI that the template was matched against.
      # @param [Addressable::Template] template
      #   The template used to match.
      # @param [Array<Hash>] candidates
      #   The variable mappings which re-expand to the URI.
      # @param [Symbol] status
      #   One of +:unique+, +:multiple+, +:no_match+, or +:truncated+.
      # @param [Array<Symbol>] truncated_reasons
      #   Reasons the result is truncated, such as +:prefix+ or
      #   +:candidate_limit+.
      def initialize(uri, template, candidates, status, truncated_reasons=[])
        @uri = uri.dup.freeze
        @template = template
        @candidates = candidates.map { |candidate|
          candidate.dup.freeze
        }.freeze
        @status = status
        @truncated_reasons = truncated_reasons.dup.freeze
      end

      ##
      # @return [Addressable::URI] The URI that was matched against.
      attr_reader :uri

      ##
      # @return [Addressable::Template] The template used for matching.
      attr_reader :template

      ##
      # @return [Array<Hash>] All candidate mappings within the configured limit.
      attr_reader :candidates

      alias_method :matches, :candidates

      ##
      # @return [Symbol] The result status.
      attr_reader :status

      ##
      # @return [Array<Symbol>] Reasons the result was truncated.
      attr_reader :truncated_reasons

      ##
      # @return [Hash, nil] The first candidate mapping, if one exists.
      def mapping
        candidates.first
      end
      alias_method :match, :mapping

      ##
      # @return [Boolean] Whether at least one candidate was found.
      def match?
        !no_match?
      end

      ##
      # @return [Boolean] Whether exactly one candidate was found.
      def unique?
        status == :unique
      end

      ##
      # @return [Boolean] Whether more than one candidate was found.
      def multiple?
        status == :multiple
      end

      ##
      # @return [Boolean] Whether no candidate was found.
      def no_match?
        status == :no_match
      end

      ##
      # @return [Boolean] Whether the result was truncated.
      def truncated?
        status == :truncated
      end

      ##
      # @return [Boolean] Whether a prefix modifier hid information.
      def prefix_truncated?
        truncated_reasons.include?(:prefix)
      end

      ##
      # @return [Boolean] Whether the candidate limit was reached.
      def candidate_limit_truncated?
        truncated_reasons.include?(:candidate_limit)
      end
    end

    StrictVariable = Struct.new(:name, :explode, :prefix_length)
    StrictExpression = Struct.new(:operator, :variables)

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
      self.strict_tokens
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
    # Performs strict reverse matching against a URI template.
    #
    # @param [Addressable::URI, #to_str] uri
    #   The URI to reverse match.
    # @param [Hash] variable_types
    #   Optional variable types. Values may be +:scalar+ (or +String+),
    #   +:list+ (or +Array+), and +:map+ (or +Hash+). Variables which are
    #   not declared are treated as scalars.
    # @param [Integer] max_candidates
    #   Maximum number of candidates to return. Defaults to 100.
    #
    # @return [Addressable::Template::StrictMatchData] The strict match result.
    def strict_match(uri, variable_types=nil, max_candidates=100)
      if !max_candidates.is_a?(Integer) || max_candidates < 1
        raise ArgumentError, "max_candidates must be a positive Integer"
      end

      uri = Addressable::URI.parse(uri) unless uri.is_a?(Addressable::URI)
      uri_string = uri.to_s
      tokens = strict_tokens
      variable_types = strict_variable_types(tokens, variable_types || {})
      suffix_positions = strict_suffix_positions(tokens, uri_string)
      suffix_positions[tokens.size] = Set.new([uri_string.length])
      candidates = []
      truncated_reasons = []
      truncated_candidates = []
      Thread.current[:addressable_template_strict_enumerations] = 0

      search = lambda do |token_index, uri_index, mapping, truncated|
        if token_index == tokens.size
          if uri_index == uri_string.length
            candidate = mapping.dup
            if self.expand(candidate).to_s == uri_string &&
                !candidates.include?(candidate)
              candidates << candidate.freeze
              truncated_candidates << truncated.dup
              throw :strict_limit if candidates.size > max_candidates
            end
          end
          next
        end

        token_type, token_value = tokens[token_index]
        if token_type == :literal
          if strict_start_at?(uri_string, token_value, uri_index)
            search.call(
              token_index + 1,
              uri_index + token_value.length,
              mapping, truncated
            )
          end
        else
          strict_expression_candidates(
            token_value, uri_string, uri_index,
            suffix_positions.fetch(token_index + 1, Set.new([uri_string.length])),
            variable_types
        ) do |consumed, local_mapping, local_truncated|
            next_index = uri_index + consumed
            next unless suffix_positions.fetch(token_index + 1, Set.new).include?(
              next_index
            )
            merged = strict_merge_mapping(
              mapping, local_mapping, truncated, local_truncated
            )
            next unless merged
            merged_mapping, merged_truncated = merged
            search.call(
              token_index + 1, next_index,
              merged_mapping, merged_truncated
            )
          end
        end
      end

      catch :strict_limit do
        search.call(0, 0, {}, Set.new)
      end

      if Thread.current[:addressable_template_strict_enumerations] >=
          STRICT_ENUMERATION_LIMIT
        truncated_reasons << :candidate_limit
      elsif candidates.size > max_candidates
        truncated_reasons << :candidate_limit
        candidates = candidates.first(max_candidates)
        truncated_candidates = truncated_candidates.first(max_candidates)
      end
      truncated_reasons << :prefix if truncated_candidates.any? { |set| !set.empty? }

      status = if candidates.empty?
        truncated_reasons.empty? ? :no_match : :truncated
      elsif !truncated_reasons.empty?
        :truncated
      elsif candidates.size == 1
        :unique
      else
        :multiple
      end

      Addressable::Template::StrictMatchData.new(
        uri, self, candidates, status, truncated_reasons
      )
    ensure
      Thread.current[:addressable_template_strict_enumerations] = nil
    end
    alias_method :strict_extract, :strict_match
    alias_method :extract_strict, :strict_match

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

    def strict_tokens
      @strict_tokens ||= begin
        tokens = []
        position = 0

        while position < pattern.length
          start = pattern.index("{", position)
          unless start
            tokens << [:literal, pattern[position..-1]] unless position == pattern.length
            break
          end

          finish = pattern.index("}", start)
          unless finish
            tokens << [:literal, pattern[position..-1]]
            break
          end

          tokens << [:literal, pattern[position...start]] unless start == position
          match = EXPRESSION.match(pattern[start..finish])
          unless match
            raise InvalidTemplateValueError,
              "Invalid URI template: #{pattern.inspect}"
          end

          operator = match[1]
          variables = match[2].split(",").map do |varspec|
            variable_match = VARSPEC.match(varspec)
            name = variable_match[1]
            modifier = variable_match[2]
            StrictVariable.new(
              name,
              modifier == "*",
              modifier && modifier.start_with?(":") ?
                modifier[1..-1].to_i : nil
            )
          end
          tokens << [:expression, StrictExpression.new(operator, variables)]
          position = finish + 1
        end

        tokens
      end
    end

    def strict_variable_types(tokens, declared)
      declared = normalize_keys(declared)
      types = {}

      tokens.each do |type, value|
        next unless type == :expression
        value.variables.each do |variable|
          variable_type = declared.fetch(variable.name, :scalar)
          variable_type =
            case variable_type
            when :scalar, :string, String then :scalar
            when :list, :array, Array then :list
            when :map, :hash, Hash then :map
            else
              raise InvalidTemplateVariableTypeError,
                "Unknown variable type: #{variable_type.inspect}"
            end
          if variable_type != :scalar && variable.prefix_length
            raise InvalidTemplateVariableTypeError,
              "Prefix modifiers require scalar variables: #{variable.name}"
          end
          if types.key?(variable.name) &&
              types[variable.name] != variable_type
            raise InvalidTemplateVariableTypeError,
              "Conflicting variable types: #{variable.name}"
          end
          types[variable.name] = variable_type
        end
      end

      declared.each do |name, _|
        unless types.key?(name)
          raise InvalidTemplateVariableTypeError,
            "Unknown template variable: #{name.inspect}"
        end
      end

      types
    end

    def strict_suffix_positions(tokens, uri)
      positions = Array.new(tokens.size)
      feasible = Set.new([uri.length])

      (tokens.size - 1).step(0, -1) do |index|
        type, value = tokens[index]
        if type == :literal
          starts = Set.new
          feasible.each do |position|
            start = position - value.length
            if start >= 0 && strict_start_at?(uri, value, start)
              starts.add(start)
            end
          end
          feasible = starts
        else
          starts = feasible.dup
          starts.add(0)
          feasible.each do |position|
            (0...position).each { |start| starts.add(start) }
          end
          feasible = starts
        end
        positions[index] = feasible
      end

      positions
    end

    def strict_expression_candidates(expression, uri, start, endings, types,
                                    &block)
      endings.sort.each do |ending|
        next if ending < start
        strict_enumerate!
        raw = uri[start...ending]
        strict_parse_variables(
          expression.operator, expression.variables, 0, raw,
          0, true, types, {}, Set.new, expression.variables, []
        ) do |consumed, mapping, truncated|
          if consumed == raw.length
            block.call(ending - start, mapping, truncated)
          end
        end
      end
    end

    def strict_parse_variables(operator, variables, index, raw, position,
                                first_present, types, mapping, truncated,
                                expression_variables = variables,
                                seen_variables = [], &block)
      if index == variables.size
        block.call(position, mapping, truncated) if position == raw.length
        return
      end

      name = variables[index].name
      existing_variable = expression_variables.find {
        |item| item.name == name
      }
      variable = existing_variable || variables[index]

      prefix = strict_variable_prefix(
        operator,
        first_present, seen_variables
      )
      present = strict_start_at?(raw, prefix, position)

      strict_assign_value(mapping, name, nil) do |without_value|
        strict_parse_variables(
          operator, variables, index + 1, raw, position,
          first_present, types, without_value, truncated,
          expression_variables, seen_variables, &block
        )
      end

      if types[name] == :list && !mapping.key?(name) &&
          [nil, "+", "#", ";"].include?(operator)
        strict_assign_value(mapping, name, []) do |with_empty_list|
          strict_parse_variables(
            operator, variables, index + 1, raw, position,
            first_present, types, with_empty_list, truncated,
            expression_variables, seen_variables, &block
          )
        end
      end

      if types[name] == :map && !mapping.key?(name)
        strict_assign_value(mapping, name, {}) do |with_empty_map|
          strict_parse_variables(
            operator, variables, index + 1, raw, position,
            first_present, types, with_empty_map, truncated,
            expression_variables, seen_variables, &block
          )
        end
      end

      return unless present

      if raw.length == position + prefix.length
        if types[name] == :map &&
            !strict_named_operator?(operator) && operator != "#"
          return
        end
        if types[name] == :list && (operator == "/" || operator == ".")
          return
        end
      end

      if types[name] == :list
        empty = strict_empty_list_expansion(operator, name, first_present)
        if strict_start_at?(raw, empty, position)
          strict_assign_value(mapping, name, []) do |with_empty|
            strict_parse_variables(
              operator, variables, index + 1, raw,
              position + empty.length, false, types, with_empty,
              truncated, expression_variables, seen_variables, &block
            )
          end
        end
      end

      body_start = position + prefix.length
      if types[name] == :scalar
        strict_parse_scalar_candidate(
          variable, operator, raw, body_start, seen_variables.empty?
        ) do |consumed, value, value_truncated|
            strict_assign_value(mapping, name, value) do |result|
              next_truncated = truncated.dup
            if value_truncated &&
                expression_variables.all? { |item|
                  item.name == name ? !!item.prefix_length : true
                }
              next_truncated.add(name)
            end
            strict_parse_variables(
              operator, variables, index + 1, raw, consumed,
              false, types, result, next_truncated,
              expression_variables,
              seen_variables + [name], &block
            )
          end
        end
      elsif types[name] == :list
        strict_parse_list_candidate(
          variable, operator, raw, body_start, seen_variables.empty?
        ) do |consumed, value|
          strict_assign_value(mapping, name, value) do |result|
            strict_parse_variables(
              operator, variables, index + 1, raw, consumed,
              false, types, result, truncated,
              expression_variables,
              seen_variables + [name], &block
            )
          end
        end
      else
        strict_parse_map_candidate(
          variable, operator, raw, body_start, seen_variables.empty?
        ) do |consumed, value|
          strict_assign_value(mapping, name, value) do |result|
            strict_parse_variables(
              operator, variables, index + 1, raw, consumed,
              false, types, result, truncated,
              expression_variables,
              seen_variables + [name], &block
            )
          end
        end
      end
    end

    def strict_parse_scalar_candidate(variable, operator, raw, position,
                                     first_present)
      strict_candidate_bodies(
        raw, position, strict_external_delimiter(operator)
      ) do |body, boundary|
        if strict_named_operator?(operator)
          value = strict_named_value(name: variable.name, body: body,
                                   operator: operator)
          next unless value
        else
          value = strict_decode(body)
        end

        is_truncated = !!variable.prefix_length &&
          variable.prefix_length <= value.length &&
          boundary == raw.length
        if variable.prefix_length
          value = value[0...variable.prefix_length] || value
        end
        yield boundary, value, is_truncated
      end
    end

    def strict_parse_list_candidate(variable, operator, raw, position,
                                   first_present)
      strict_candidate_bodies(
        raw, position, strict_external_delimiter(operator)
      ) do |body, boundary|
        strict_list_values(variable, operator, body) do |values|
          yield boundary, values
        end
      end
    end

    def strict_parse_map_candidate(variable, operator, raw, position,
                                  first_present)
      strict_candidate_bodies(
        raw, position, strict_external_delimiter(operator)
      ) do |body, boundary|
        if strict_named_operator?(operator) && !variable.explode
          body = strict_named_value(name: variable.name, body: body,
                                   operator: operator)
          next unless body
        end

      if variable.explode
        separator = strict_internal_separator(operator)
        parts = body.split(separator, -1)
        strict_each_partition(parts, separator) do |groups|
          valid = groups.all? do |group|
            if operator == ";" && !group.include?("=")
              true
            elsif group.include?("=")
              positions = strict_equals_positions(group, operator)
              !positions.empty?
            else
              false
            end
          end
          next unless valid

          mappings = [{}]
          groups.each do |group|
            mappings = strict_append_map_group(
              mappings, group, operator
            )
          end
          mappings.each { |mapping| yield boundary, mapping }
        end
      else
        parts = body.split(",", -1)
        if operator == "+" || operator == "#"
          strict_each_partition(parts, ",") do |groups|
            next unless groups.size.even? && !groups.empty?
            mapping = {}
            groups.each_slice(2) do |key, value|
              mapping[strict_decode(key)] = strict_decode(value)
            end
            yield boundary, mapping
          end
        else
          next if parts.empty? || parts.size.odd?
          mapping = {}
          parts.each_slice(2) do |key, value|
            mapping[strict_decode(key)] = strict_decode(value)
          end
          yield boundary, mapping
        end
      end
      end
    end

    def strict_candidate_bodies(raw, position, delimiter)
      boundaries = [raw.length]
      if delimiter
        search_position = position
        while search_position <= raw.length &&
            found = raw.index(delimiter, search_position)
          boundaries << found
          search_position = found + 1
        end
      end

      boundaries.sort.uniq.each do |boundary|
        next if boundary < position
        yield raw[position...boundary], boundary
      end
    end

    def strict_list_values(variable, operator, body)
      separator = variable.explode ?
        strict_internal_separator(operator) : ","
      parts = body.split(separator, -1)

      if strict_named_operator?(operator) && variable.explode
        prefix = "#{variable.name}="
        unless parts.all? { |part| part.start_with?(prefix) }
          return
        end
        parts.map! { |part| part[prefix.length..-1] }
      elsif strict_named_operator?(operator)
        unless body.start_with?("#{variable.name}=") || body.empty?
          return
        end
        body = body[(variable.name.length + 1)..-1] if body
        parts = body.to_s.split(",", -1)
        parts = [] if body.nil? || body.empty?
      end

      ambiguous = variable.explode ? operator == "." :
        operator == "+" || operator == "#"
      if ambiguous
        strict_each_partition(parts, separator) do |groups|
          yield groups.map { |group| strict_decode(group) }
        end
      else
        yield parts.map { |part| strict_decode(part) }
      end
    end

    def strict_exploded_map_pairs(group, operator)
      if operator == ";" && !group.include?("=")
        yield [strict_decode(group), ""]
      elsif group.include?("=")
        strict_equals_positions(group, operator).each do |equals|
          yield [
            strict_decode(group[0...equals]),
            strict_decode(group[(equals + 1)..-1])
          ]
        end
      end
    end

    def strict_equals_positions(group, operator)
      positions = []
      search_position = 0
      while search_position < group.length &&
          found = group.index("=", search_position)
        positions << found
        search_position = found + 1
      end
      if operator != "+" && operator != "#" && !positions.empty?
        positions = [positions.first]
      end
      positions
    end

    def strict_append_map_group(mappings, group, operator)
      next_mappings = []
      mappings.each do |mapping|
        strict_exploded_map_pairs(group, operator) do |pair|
          unless mapping.key?(pair[0])
            next_mapping = mapping.dup
            next_mapping[pair[0]] = pair[1]
            next_mappings << next_mapping
          end
        end
      end
      next_mappings
    end

    def strict_each_partition(parts, separator = ",")
      if parts.empty?
        yield []
        return
      end

      partition = Array.new(parts.size - 1, false)
      loop do
        groups = []
        current = parts.first
        partition.each_with_index do |split, index|
          if split
            groups << current
            current = parts[index + 1]
          else
            current += separator + parts[index + 1]
          end
        end
        groups << current
        strict_enumerate!
        yield groups

        index = partition.rindex(false)
        break unless index
        partition[index] = true
        (index + 1...partition.size).each { |i| partition[i] = false }
      end
    end

    def strict_named_value(name:, body:, operator:)
      if operator == ";"
        return "" if body == name
        prefix = "#{name}="
        return body[prefix.length..-1] if body.start_with?(prefix)
      elsif body.start_with?("#{name}=")
        return body[(name.length + 1)..-1]
      end
      nil
    end

    def strict_decode(value)
      Addressable::URI.unencode_component(value).unicode_normalize(:nfc)
    end

    def strict_enumerate!
      count = (Thread.current[:addressable_template_strict_enumerations] || 0) + 1
      Thread.current[:addressable_template_strict_enumerations] = count
      throw :strict_limit if count > STRICT_ENUMERATION_LIMIT
    end

    def strict_start_at?(string, prefix, position)
      position >= 0 && string[position, prefix.length] == prefix
    end

    def strict_assign_value(mapping, name, value)
      if mapping.key?(name) && mapping[name] != value
        nil
      else
        result = mapping.dup
        result[name] = value
        if block_given?
          yield result
        else
          result
        end
      end
    end

    def strict_variable_prefix(operator, first_present, seen_variables)
      if first_present
        LEADERS.fetch(operator, "")
      else
        seen_variables.empty? ? LEADERS.fetch(operator, "") :
          (operator == "?" ? JOINERS[operator] :
            LEADERS.fetch(operator, JOINERS.fetch(operator, ",")))
      end
    end

    def strict_external_delimiter(operator)
      case operator
      when nil, "+", "#" then ","
      else JOINERS[operator]
      end
    end

    def strict_internal_separator(operator)
      case operator
      when nil, "+", "#" then ","
      else JOINERS[operator]
      end
    end

    def strict_named_operator?(operator)
      operator == ";" || operator == "?" || operator == "&"
    end

    def strict_empty_list_expansion(operator, name, first_present)
      case operator
      when nil, "+"
        first_present ? "" : ","
      when "#"
        first_present ? "#" : ","
      when "/", "."
        (first_present ? "" : strict_external_delimiter(operator)) +
          LEADERS[operator]
      when ";"
        (first_present ? "" : ";") + ";#{name}"
      when "?", "&"
        (first_present ? LEADERS[operator] : "&") +
          "#{name}="
      end
    end

    def strict_merge_mapping(mapping, local_mapping, _truncated, _local)
      result = mapping.dup
      truncated = _truncated.dup
      resolved_names = Set.new
      local_mapping.each do |name, value|
        if result.key?(name) && result[name] != value
          local_truncated = _local.include?(name)
          previous_truncated = _truncated.include?(name)
          return nil unless local_truncated || previous_truncated
          if local_truncated && !previous_truncated
            prefix = value
            full = result[name]
          else
            prefix = result[name]
            full = value
          end
          return nil unless full.is_a?(String) && prefix.is_a?(String) &&
            full.start_with?(prefix)
          result[name] = full
          truncated.delete(name) if !local_truncated || !previous_truncated
          resolved_names.add(name)
          next
        end
        result[name] = value
      end
      _local.each do |name|
        truncated.add(name) unless resolved_names.include?(name)
      end
      [result, truncated]
    end

    def strict_prefix_truncated?(tokens, mapping, name)
      value = mapping[name]
      return false unless value.is_a?(String)
      occurrences = tokens.flat_map do |type, expression|
        next [] unless type == :expression
        expression.variables.select { |variable| variable.name == name }
      end
      occurrences.all? { |variable| variable.prefix_length } &&
        occurrences.any? { |variable| variable.prefix_length < value.length }
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

  end
end
