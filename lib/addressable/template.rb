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
require "set"

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
    # This class represents the result of a type-aware reverse expansion.
    class ReverseExpansion
      include Enumerable

      ##
      # @api private
      def initialize(uri, template, candidates, complete, limit_reached, reasons)
        @uri = uri.dup.freeze
        @template = template
        @candidates = candidates.each { |candidate| candidate.freeze }.freeze
        @complete = complete
        @limit_reached = limit_reached
        @reasons = reasons.to_a.uniq.freeze
      end

      # @return [Addressable::URI] The URI that was reverse expanded.
      attr_reader :uri

      # @return [Addressable::Template] The template used for the search.
      attr_reader :template

      # @return [Array<Hash>] Every mapping found before the candidate limit.
      attr_reader :candidates

      # @return [Array<Symbol>] Machine-readable explanations, including
      #   `:adjacent_variables`, `:prefix_truncation`, `:empty_value`, and
      #   `:duplicate_key`.
      attr_reader :reasons

      def each(&block)
        candidates.each(&block)
      end

      # @return [Hash, nil] The only candidate, or nil when ambiguous.
      def candidate
        if unique?
          candidates.first
        elsif prefix_truncation?
          candidates.find { |candidate| candidate.values.include?("") } ||
            candidates.first
        end
      end

      # @return [Boolean] Whether at least one candidate was found.
      def match?
        !candidates.empty?
      end

      # @return [Boolean] Whether exactly one candidate was found.
      def unique?
        candidates.size == 1
      end

      # @return [Boolean] Whether no candidate was found.
      def no_solution?
        candidates.empty?
      end

      # @return [Boolean] Whether more than one candidate was found.
      def ambiguous?
        prefix_truncation? || candidates.size > 1
      end

      def prefix_truncation?
        reasons.include?(:prefix_truncation)
      end

      # @return [Boolean] Whether the search exhausted all candidates.
      def complete?
        @complete
      end

      # @return [Boolean] Whether the candidate limit stopped enumeration.
      def limit_reached?
        @limit_reached && !reasons.include?(:prefix_truncation)
      end

      # @return [Symbol] The result state.
      def status
        return :limit_reached if candidates.empty? && !complete?
        return :no_solution if candidates.empty?
        return :prefix_truncation if prefix_truncation?
        return :limit_reached unless complete?
        return :unique if candidates.size == 1
        :ambiguous
      end

      # @return [String] A short explanation of the result.
      def message
        case status
        when :no_solution
          "No mapping expands to the supplied URI."
        when :prefix_truncation
          "Prefix expansion discards information; the displayed candidate " +
            "is one of infinitely many mappings."
        when :unique
          "Found one mapping."
        when :limit_reached
          "Found #{candidates.size} candidate(s); enumeration was stopped " +
            "before all candidates were expanded."
        else
          "Found #{candidates.size} mappings that expand to the supplied URI."
        end
      end

      # @return [Hash, nil] The only candidate, or nil when ambiguous.
      def to_h
        candidate
      end

      def inspect
        "#<#{self.class} status=#{status.inspect} " +
          "candidates=#{candidates.inspect}>"
      end
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
    # Reverse-expands a URI using declared variable types. Every returned
    # mapping is verified by expanding it with this template and comparing
    # the result to `uri`.
    #
    # Types are `:string`, `:list`, and `:hash`; an Array may be used to
    # request more than one possible type. A variable declared as both list
    # and hash can reveal representations shared by those two types.
    # Result states are `:unique`, `:ambiguous`, `:prefix_truncation`,
    # `:limit_reached`, and `:no_solution`.
    #
    # @param [Addressable::URI, #to_str] uri The URI to reverse-expand.
    # @param [Hash] types Variable names to allowed types.
    # @param [Integer, nil] max_candidates
    #   Optional limit on verified mappings. `nil` exhausts the search.
    #
    # @return [Addressable::Template::ReverseExpansion]
    def reverse_expand(uri, types, max_candidates=nil)
      unless max_candidates.nil? ||
          (max_candidates.is_a?(Integer) && max_candidates > 0)
        raise ArgumentError, "max_candidates must be a positive Integer."
      end
      uri = Addressable::URI.parse(uri) unless uri.is_a?(Addressable::URI)
      type_map = normalize_reverse_types(types)
      search = ReverseCandidateSearch.new(
        self, uri.to_str, type_map, max_candidates
      )
      search.run
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
    def normalize_reverse_types(types)
      unless types.is_a?(Hash)
        raise TypeError, "Expected a Hash of variable type declarations."
      end

      type_map = {}
      types.each do |name, allowed_types|
        name = name.to_s if Symbol === name
        unless name.respond_to?(:to_str)
          raise TypeError, "Can't convert #{name.class} into String."
        end
        name = name.to_str
        unless variables.include?(name)
          raise ArgumentError, "Unknown template variable: #{name.inspect}."
        end

        allowed = Array(allowed_types).map do |type|
          type = type.to_s if Symbol === type
          unless %w(string list hash).include?(type)
            raise ArgumentError,
              "Invalid type #{type.inspect} for #{name.inspect}. " +
              "Valid types are :string, :list, and :hash."
          end
          type
        end.uniq

        if type_map.key?(name) && type_map[name] != allowed
          raise ArgumentError,
            "Conflicting type declarations for #{name.inspect}."
        end
        type_map[name] = allowed
      end

      variables.each do |name|
        type_map[name] ||= ["string"]
      end
      type_map
    end

    class ReverseCandidateSearch
      UNASSIGNED = Object.new.freeze

      def initialize(template, uri, types, max_candidates)
        @template = template
        @uri = uri
        @types = types
        @max_candidates = max_candidates
        @variable_names = template.variables
        @tokens = build_tokens
        @candidates = []
        @reasons = []
        @complete = true
        @stopped_by_limit = false
      end

      def run
        values = Array.new(@variable_names.size) { UNASSIGNED }
        search_tokens(@tokens, 0, 0, values, Set.new)
        if @candidates.size > 1 &&
           @candidates.combination(2).any? do |left, right|
             empty_value_ambiguity?(left, right)
           end
          @reasons << :empty_value
        end
        ReverseExpansion.new(
          Addressable::URI.parse(@uri),
          @template,
          @candidates,
          @complete,
          @stopped_by_limit,
          @reasons
        )
      end

      private
      def empty_value_ambiguity?(left, right)
        keys = left.keys | right.keys
        keys.any? do |key|
          left_empty = empty_value?(left.fetch(key, nil))
          right_empty = empty_value?(right.fetch(key, nil))
          left_empty != right_empty ||
            (left_empty && right_empty && left[key] != right[key])
        end
      end

      def empty_value?(value)
        value.nil? || value == "" || value == [] || value == {}
      end

      def build_tokens
        tokens = []
        position = 0
        match = EXPRESSION.match(@template.pattern, position)
        while match
          unless match.begin(0) == position
            tokens << [:literal, @template.pattern[position...match.begin(0)]]
          end
          _, operator, varlist = *match
          specs = varlist.split(",").map do |varspec|
            spec_match = VARSPEC.match(varspec)
            {
              name: spec_match[1],
              modifier: spec_match[2],
              types: @types[spec_match[1]]
            }
          end
          tokens << [:expression, operator, specs]
          position = match.end(0)
          match = EXPRESSION.match(@template.pattern, position)
        end
        if position < @template.pattern.size
          tokens << [:literal, @template.pattern[position..-1]]
        end
        tokens
      end

      def search_tokens(tokens, index, position, values,
                        candidate_reasons)
        return if @stopped_by_limit

        if index >= tokens.size
          if position == @uri.size
            candidate_reasons = candidate_reasons + adjacent_reasons(tokens)
            emit_candidate(values, candidate_reasons)
          end
          return
        end

        token = tokens[index]
        if token.first == :literal
          literal = token.last
          if percent_encoding_equal?(@uri[position, literal.size], literal)
            search_tokens(
              tokens, index + 1, position + literal.size,
              values, candidate_reasons
            )
          end
          return
        end

        operator = token[1]
        specs = token[2]
        leader = LEADERS.fetch(operator, "")

        parse_omitted_expression(
          tokens, index, position, operator, specs,
          values, candidate_reasons
        )

        unless leader.empty?
          if @uri[position, leader.size] == leader
          parse_present_expression(
              tokens, index, position + leader.size, true,
              operator, specs, values, candidate_reasons
            )
          end
        else
          parse_present_expression(
              tokens, index, position, false, operator, specs,
              values, candidate_reasons
          )
        end
      end

      def adjacent_reasons(tokens)
        tokens.each_cons(2).any? do |left, right|
          left.first == :expression && right.first == :expression &&
            (left[1].nil? || left[1] == "+") &&
            (right[1].nil? || right[1] == "+")
        end ? [:adjacent_variables] : []
      end

      def parse_omitted_expression(tokens, index, position, operator,
                                   specs, values, candidate_reasons)
        next_reasons = candidate_reasons

        enumerate_absent_specs(specs, 0, values) do |assigned_values|
          adjacent_ambiguity = false
          if operator.nil? || operator == "+"
            next_token = tokens[index + 1]
            if next_token && next_token.first == :expression &&
               (next_token[1].nil? || next_token[1] == "+")
              adjacent_ambiguity = true
            end
          end
          following_reasons =
            adjacent_ambiguity ? [:adjacent_variables] : []
          search_tokens(
             tokens, index + 1, position, assigned_values,
             next_reasons + following_reasons
          )
        end
      end

      def enumerate_absent_specs(specs, spec_index, values)
        if spec_index >= specs.size
          yield values
          return
        end

        spec = specs[spec_index]
        absent_values(spec).each do |value|
          result = assign_value(values, spec, value)
          next unless result
          next_values, _ = result
          enumerate_absent_specs(
            specs, spec_index + 1, next_values
          ) { |assigned| yield assigned }
        end
      end

      def absent_values(spec)
        if spec[:types].include?("hash")
          [nil, {}]
        else
          [nil]
        end
      end

      def parse_present_expression(tokens, index, body_start, leader_present,
                                   operator,
                                   specs, values, candidate_reasons)
        minimum_end = next_literal_start(tokens, index + 1, body_start)
        return if minimum_end.nil?
        maximum_end = last_literal_start(tokens, index + 1, minimum_end)
        (body_start..maximum_end).each do |body_end|
          parse_specs(
            specs, 0, body_start, body_end, true,
            operator, leader_present, tokens, index, values,
            candidate_reasons
          )
          return if @stopped_by_limit
        end
      end

      def next_literal_start(tokens, index, minimum)
        return minimum if index >= tokens.size
        token = tokens[index]
        if token.first == :literal
          @uri.index(token.last, minimum)
        else
          minimum
        end
      end

      def last_literal_start(tokens, index, minimum)
        return @uri.size if index >= tokens.size
        token = tokens[index]
        return @uri.size if token.first != :literal

        literal = token.last
        position = nil
        search_start = minimum
        while (found = @uri.index(literal, search_start))
          position = found
          search_start = found + [literal.size, 1].max
        end
        position || -1
      end

      def parse_specs(specs, spec_index, start_position, end_position,
                      prefix, operator, leader_present, tokens, token_index,
                      values,
                      candidate_reasons)
        return if @stopped_by_limit

        if spec_index >= specs.size
          if start_position == end_position
            search_tokens(
              tokens, token_index + 1, end_position,
              values, candidate_reasons
            )
          end
          return
        end

        spec = specs[spec_index]
        separator = variable_separator(operator)

        if prefix
          value_start = start_position
          if start_position == end_position
            assign_omitted_specs(
              specs, spec_index, start_position, end_position,
              operator, tokens, token_index, values, candidate_reasons
            )
          end
          if spec_index == 0 && start_position < end_position &&
             (next_start = omitted_first_spec_start(
               specs, spec_index, start_position, operator
             ))
            absent_values(spec).each do |absent_value|
              assign_value(values, spec, absent_value) do |next_values, reasons|
                parse_specs(
                  specs, spec_index + 1, next_start, end_position, true,
                  operator, false, tokens, token_index, next_values,
                  candidate_reasons | reasons
                )
              end
            end
          end
        else
          if start_position == end_position
            assign_omitted_specs(
              specs, spec_index, start_position, end_position,
              operator, tokens, token_index, values, candidate_reasons
            )
            return
          end
          return if start_position >= end_position
          return unless @uri[start_position, separator.size] == separator
          value_start = start_position + separator.size
        end

        if !prefix && value_start <= end_position &&
            @uri[start_position, separator.size] == separator
          absent_values(spec).each do |absent_value|
            assign_value(values, spec, absent_value) do |next_values, reasons|
              parse_specs(
                specs, spec_index + 1, value_start, end_position, true,
                operator, leader_present, tokens, token_index, next_values,
                candidate_reasons | reasons
              )
            end
          end
        end

        (value_start..end_position).each do |cut|
          raw = @uri[value_start...cut]
          allow_empty_composite = !prefix || !leader_present
          variable_options(
            spec, operator, raw, allow_empty_composite
          ).each do |value, option_reasons|
            assign_value(values, spec, value) do |next_values, assign_reasons|
              parse_specs(
                specs, spec_index + 1, cut, end_position, false,
                operator, leader_present, tokens, token_index,
                next_values,
                candidate_reasons | option_reasons | assign_reasons
              )
            end
          end
          return if @stopped_by_limit
        end
      end

      def assign_omitted_specs(specs, spec_index, position, end_position,
                               operator, tokens, token_index, values,
                               candidate_reasons)
        return unless position == end_position
        enumerate_absent_specs(specs, spec_index, values) do |next_values|
          search_tokens(
            tokens, token_index + 1, position, next_values,
            candidate_reasons
          )
        end
      end

      def omitted_first_spec_start(specs, spec_index, start_position, operator)
        next_spec = specs[spec_index + 1]
        return nil unless next_spec

        label = next_spec[:name]
        case operator
        when "?", "&"
          label_with_equals = "#{label}="
          start_position if @uri[start_position, label_with_equals.size] ==
            label_with_equals
        when ";"
          label_with_equals = "#{label}="
          if @uri[start_position, label_with_equals.size] ==
              label_with_equals
            start_position
          elsif @uri[start_position, label.size] == label
            start_position
          end
        else
          start_position
        end
      end

      def variable_separator(operator)
        case operator
        when "?", "&"
          "&"
        when ";"
          ";"
        when ".", "/"
          operator
        else
          ","
        end
      end

      def assign_value(values, spec, value)
        index = @variable_names.index(spec[:name])
        if values[index] != UNASSIGNED && values[index] != value
          if block_given?
            return
          else
            return nil
          end
        end

        next_values = values.dup
        next_values[index] = value
        if block_given?
          yield next_values, Set.new
        else
          [next_values, Set.new]
        end
      end

      def variable_options(spec, operator, raw, allow_empty_composite)
        options = []
        spec[:types].each do |type|
          if type == "string"
            string_options(spec, operator, raw).each do |option|
              options << option
            end
          elsif type == "list"
            list_options(
              spec, operator, raw, allow_empty_composite
            ).each { |option| options << option }
          else
            hash_options(
              spec, operator, raw, allow_empty_composite
            ).each { |option| options << option }
          end
        end
        options
      end

      def string_options(spec, operator, raw)
        return [[nil, Set.new]] if raw.nil?
        stripped_raw = strip_nonexplode_label(spec, raw, operator)
        return [] unless stripped_raw
        value = decode_scalar(stripped_raw, operator, true)
        return [] unless value
        reasons = Set.new
        if spec[:modifier] =~ /^:(\d+)$/
          limit = $1.to_i
          if value.size >= limit
            reasons << :prefix_truncation
          end
        elsif spec[:modifier] == "*" &&
            (operator.nil? || operator == "+" || operator == "#") &&
            contains_separator?(raw, ",")
          reasons << :explode_separator
        end
        [[value, reasons]]
      rescue ArgumentError
        []
      end

      def list_options(spec, operator, raw, allow_empty_composite)
        return [[nil, Set.new]] if raw.nil?
        return [] if prefix_spec?(spec)
        candidate_values =
          if spec[:modifier] == "*"
            explode_list(spec, raw, operator)
          else
            nonexplode_list(spec, raw, operator)
          end
        return [] unless candidate_values

        candidate_values.map do |value|
          reasons = Set.new
          if value.is_a?(Array) && value.empty? &&
              list_empty_value_ambiguous?(operator)
            reasons << :empty_value
          end
          [value, reasons]
        end
      rescue ArgumentError
        []
      end

      def nonexplode_list(spec, raw, operator)
        raw = strip_nonexplode_label(spec, raw, operator)
        return nil unless raw

        if reserved_operator?(operator)
          values = []
          each_encoded_partition(raw, ",") do |parts|
            decoded = parts.map do |part|
              value = decode_scalar(part, operator, true)
              break nil unless value
              value
            end
            values << decoded if decoded
          end
          values
        else
          [raw.split(",", -1).map do |part|
             value = decode_scalar(part, operator, false)
             break nil unless value
             value
           end]
        end
      end

      def each_encoded_partition(raw, separator, &block)
        positions = separator_positions(raw, separator)
        each_choice(positions) do |chosen|
          yield split_at(raw, chosen, separator)
        end
      end

      def separator_positions(raw, separator)
        positions = []
        index = 0
        while index <= raw.size - separator.size
          if !inside_percent_encoding?(raw, index) &&
              raw[index, separator.size] == separator
            positions << index
          end
          index += 1
        end
        positions
      end

      def first_unencoded_position(raw, separator, start = 0)
        index = start
        while index <= raw.size - separator.size
          if !inside_percent_encoding?(raw, index) &&
              raw[index, separator.size] == separator
            return index
          end
          index += 1
        end
        nil
      end

      def each_choice(positions)
        (0..positions.size).each do |count|
          positions.combination(count) do |chosen|
            yield chosen
          end
        end
      end

      def split_at(raw, positions, separator)
        parts = []
        start = 0
        positions.each do |position|
          parts << raw[start...position]
          start = position + separator.size
        end
        parts << raw[start..-1]
        parts
      end

      def limit_reached(count)
        @max_candidates && count >= @max_candidates
      end

      def explode_list(spec, raw, operator)
        case operator
        when ";", "?", "&"
          separator = operator == ";" ? ";" : "&"
          entries = split_encoded(raw, separator)
          values = entries.map do |entry|
            label = "#{spec[:name]}="
            return nil unless entry.start_with?(label)
            value = decode_scalar(entry[label.size..-1], operator, false)
            return nil unless value
            value
          end
          [values]
        when ".", "/"
          entries = split_encoded(raw, operator)
          [entries.map do |entry|
             value = decode_scalar(entry, operator, false)
             break nil unless value
             value
           end]
        else
          values = []
          each_encoded_partition(raw, ",") do |parts|
            decoded = parts.map do |part|
              value = decode_scalar(part, operator, true)
              break nil unless value
              value
            end
            values << decoded if decoded
          end
          values
        end
      end

      def hash_options(spec, operator, raw, allow_empty_composite)
        return [[nil, Set.new]] if raw.nil?
        return [] if prefix_spec?(spec)
        if raw.empty?
          return [[{}, Set.new]] unless leader?(operator)
          return []
        end
        options = []
        if spec[:modifier] == "*"
          explode_hash_options(raw, operator, options)
        else
          nonexplode_hash_options(spec, raw, operator, options)
        end
        options
      rescue ArgumentError
        options
      end

      def nonexplode_hash_options(spec, raw, operator, options)
        raw = strip_nonexplode_label(spec, raw, operator)
        return unless raw

        if reserved_operator?(operator)
          atom_parts = split_encoded(raw, ",")
          each_field_partition(atom_parts, 2) do |pairs|
            hash = {}
            valid = true
            pairs.each do |encoded_key, encoded_value|
              key = decode_scalar(encoded_key, operator)
              value = decode_scalar(encoded_value, operator)
              unless key && value && !hash.key?(key)
                valid = false
                break
              end
              hash[key] = value
            end
            options << [hash, Set.new] if valid
            return if limit_reached(options.size)
          end
        else
          parts = raw.split(",", -1)
          return unless parts.size.even?
          hash = {}
          parts.each_slice(2) do |encoded_key, encoded_value|
            key = decode_scalar(encoded_key, operator, true)
            value = decode_scalar(encoded_value, operator, true)
            return unless key && value
            return if hash.key?(key)
            hash[key] = value
          end
          options << [hash, Set.new]
        end
      end

      def explode_hash_options(raw, operator, options)
        case operator
        when ";", "?", "&"
          separator = operator == ";" ? ";" : "&"
          pairs = split_encoded(raw, separator)
          hash = {}
          pairs.each do |pair|
            position = first_unencoded_position(pair, "=")
            return unless position
            key = decode_scalar(pair[0...position], operator, false)
            value = decode_scalar(pair[(position + 1)..-1], operator, false)
            return unless key && value
            if hash.key?(key)
              @reasons << :duplicate_key
              return
            end
            hash[key] = value
          end
          options << [hash, Set.new]
        when ".", "/"
          separator = operator
          positions = separator_positions(raw, separator)
          each_choice(positions) do |chosen|
            pairs = split_at(raw, chosen, separator)
            hash = hash_from_pairs(pairs, operator)
            options << [hash, Set.new] if hash
            return if limit_reached(options.size)
          end
        else
          if reserved_operator?(operator)
            each_encoded_partition(raw, ",") do |pairs|
              next unless pairs.size >= 1 && pairs.all? do |pair|
                first_unencoded_position(pair, "=")
              end
              candidate = hash_from_pairs(pairs, operator, true)
              if candidate
                options << [candidate, Set.new]
                return if limit_reached(options.size)
              end
            end
          else
            hash = hash_from_pairs(split_encoded(raw, ","), operator)
            options << [hash, Set.new] if hash
          end
        end
      end

      def each_field_partition(parts, fields_per_record)
        partition_records = lambda do |remaining, records|
          if remaining.empty?
            yield records
            return
          end

          min_atoms = [fields_per_record, remaining.size].min
          (min_atoms..remaining.size).each do |record_atoms|
            segment = remaining[0...record_atoms].join(",")
            split_position = segment.rindex(",")
            next unless split_position
            record = [
              segment[0...split_position],
              segment[(split_position + 1)..-1]
            ]
            partition_records.call(
              remaining[record_atoms..-1] || [],
              records + [record]
            )
          end
        end
        partition_records.call(parts, [])
      end

      def hash_from_pairs(pairs, operator, allow_separators=false)
        hash = {}
        pairs.each do |pair|
          position = first_unencoded_position(pair, "=")
          return nil unless position
          key = decode_scalar(
            pair[0...position], operator, allow_separators
          )
          value = decode_scalar(
            pair[(position + 1)..-1], operator, allow_separators
          )
          return nil unless key && value
          return nil if hash.key?(key)
          hash[key] = value
        end
        hash
      end

      def strip_nonexplode_label(spec, raw, operator)
        case operator
        when ";"
          if raw == spec[:name]
            ""
          elsif raw.start_with?("#{spec[:name]}=")
            raw[(spec[:name].size + 1)..-1]
          end
        when "?", "&"
          label = "#{spec[:name]}="
          raw[label.size..-1] if raw.start_with?(label)
        else
          raw
        end
      end

      def list_empty_value_ambiguous?(operator)
        ["#", ".", "/", ";", "?", "&"].include?(operator)
      end

      def reserved_operator?(operator)
        operator == "+" || operator == "#"
      end

      def prefix_spec?(spec)
        !!(spec[:modifier] =~ /^:\d+$/)
      end

      def leader?(operator)
        ["#", ".", "/", ";", "?", "&"].include?(operator)
      end

      def decode_scalar(raw, operator, allow_separators=false)
        decoded = Addressable::URI.unencode_component(raw)
        return nil if decoded.nil?
        decoded = decoded.unicode_normalize(:nfc)
        encode_map = decode_encode_map(operator, allow_separators)
        encoded = Addressable::URI.encode_component(decoded, encode_map)
        return nil unless encoded == raw
        decoded
      rescue ArgumentError, EncodingError
        nil
      end

      def decode_encode_map(operator, allow_separators)
        map =
          if reserved_operator?(operator)
            Addressable::URI::CharacterClasses::RESERVED +
              Addressable::URI::CharacterClasses::UNRESERVED
          else
            Addressable::URI::CharacterClasses::UNRESERVED
          end
        unless allow_separators
          map.delete(",")
          map.delete("=")
        end
        map
      end

      def split_encoded(raw, separator)
        parts = []
        start = 0
        index = 0
        while index <= raw.size - separator.size
          unless inside_percent_encoding?(raw, index)
            if raw[index, separator.size] == separator
              parts << raw[start...index]
              start = index + separator.size
              index = start
              next
            end
          end
          index += 1
        end
        parts << raw[start..-1]
        parts
      end

      def contains_separator?(raw, separator)
        split_encoded(raw, separator).size > 1
      end

      def inside_percent_encoding?(string, index)
        index >= 2 && string[index - 2] == "%" &&
          string[index - 1] =~ /\A[0-9a-fA-F]\z/
      end

      def emit_candidate(values, reasons)
        mapping = {}
        @variable_names.each_with_index do |name, index|
          value = values[index]
          mapping[name] = value if value != UNASSIGNED
        end

        expanded = normalize_percent_encoding(
          @template.expand(mapping).to_str
        )
        return unless expanded == normalize_percent_encoding(@uri)

        return if @candidates.include?(mapping)
        if @max_candidates && @candidates.size >= @max_candidates
          @complete = false
          @stopped_by_limit = true
          return
        end

        @candidates << mapping
        reasons.each { |reason| @reasons << reason }
        if reasons.include?(:prefix_truncation)
          @complete = false
          @prefix_truncated = true
          @stopped_by_limit = true
        end
      end

      def normalize_percent_encoding(string)
        string.gsub(/%[0-9a-fA-F]{2}/, &:upcase)
      end

      def percent_encoding_equal?(actual, expected)
        normalize_percent_encoding(actual) ==
          normalize_percent_encoding(expected)
      end
    end

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
