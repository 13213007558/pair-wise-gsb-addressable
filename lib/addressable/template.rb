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
    # This class represents a set of proven mappings returned by a typed
    # reverse expansion. Every candidate is verified by expanding it with the
    # original template.
    class CandidateSet
      include Enumerable

      # @api private
      def initialize(candidates, ambiguities = [], complete = true,
                     truncated = false)
        @candidates = candidates.dup.freeze
        @ambiguities = ambiguities.dup.freeze
        @complete = complete && !truncated
        @truncated = truncated
      end

      # @return [Array<Hash>] The verified candidate mappings.
      attr_reader :candidates

      # @return [Array<Hash>] Machine-readable ambiguity explanations.
      attr_reader :ambiguities

      # @return [Boolean] Whether the finite candidate set was fully enumerated.
      def complete?
        @complete
      end

      # @return [Boolean] Whether the supplied candidate limit was reached.
      def truncated?
        @truncated
      end

      # @return [Boolean] Whether there is no proven candidate.
      def no_solution?
        complete? && candidates.empty?
      end

      # @return [Boolean] Whether the inverse is known to have more than one
      #   compatible interpretation or a structurally unbounded ambiguity.
      def ambiguous?
        candidates.size > 1 || !complete? || !ambiguities.empty?
      end

      def each(&block)
        candidates.each(&block)
      end

      def size
        candidates.size
      end
      alias_method :length, :size

      def [](index)
        candidates[index]
      end

      def first
        candidates.first
      end

      def to_a
        candidates.dup
      end

      def inspect
        "#<#{self.class} candidates=#{candidates.inspect} " \
          "complete=#{complete?} truncated=#{truncated?} " \
          "ambiguities=#{ambiguities.inspect}>"
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
    # Performs a typed reverse expansion. Unlike {#extract}, this method does
    # not guess whether an expanded value was a scalar, list, or map. Callers
    # declare the accepted RFC 6570 variable types for each template variable.
    #
    # Types are +:scalar+ (also +:string+), +:list+ (also +:array+), and
    # +:map+ (also +:hash+). A variable may accept several types by providing
    # them in an Array. Every returned candidate is verified by expanding it
    # against this template. The result also distinguishes an actual lack of a
    # solution from ambiguities whose candidate set was not fully enumerated.
    #
    # Prefix modifiers, adjacent expansions without separators, duplicate map
    # keys, and indistinguishable empty and missing values may make a template
    # non-invertible. Such cases are reported as ambiguity rather than resolved
    # by choosing an arbitrary mapping.
    #
    # @param [Addressable::URI, #to_str] uri The URI to reverse expand.
    # @param [Hash] types Variable names mapped to one or more accepted types.
    # @param [Integer, nil] limit Maximum number of verified candidates.
    #   Defaults to 100; use +nil+ to request an exhaustive result.
    # @param [Boolean] normalize_values Whether to NFC normalize candidates.
    #
    # @return [Addressable::Template::CandidateSet]
    def extract_candidates(uri, types, limit=100, normalize_values=true)
      if !limit.nil? && (!limit.is_a?(Integer) || limit < 0)
        raise ArgumentError, "limit must be a non-negative Integer or nil"
      end
      TypedExtractor.new(self, normalize_keys(types), limit, normalize_values)
        .extract(uri)
    end

    # @see #extract_candidates
    alias_method :reverse_expand, :extract_candidates

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

    TYPE_ALIASES = {
      "scalar" => :scalar,
      "string" => :scalar,
      "list" => :list,
      "array" => :list,
      "map" => :map,
      "hash" => :map
    }.freeze

    class TypedExtractor
      def initialize(template, types, limit, normalize_values)
        @template = template
        @limit = limit
        @normalize_values = normalize_values
        @types = normalize_types(types)
        @prefix_ambiguity = false
        @spec_index = 0
        @specs_by_key = {}
      end

      def extract(uri)
        @target = uri.is_a?(Addressable::URI) ? uri.to_str : uri.to_str
        target = @target
        states = [new_state]

        tokens.each do |token|
          if token[:literal]
            states = states.flat_map do |state|
              position = state[:position]
              if target[position, token[:literal].length] == token[:literal]
                [advance(state, token[:literal].length)]
              else
                []
              end
            end
          end

          if token[:expression]
            states = states.flat_map do |state|
              parsed = parse_expression(token, target, state[:position])
              parsed.map { |candidate| merge_expression(state, candidate) }
            end.compact
            states = prune_states(states)
          end
        end

        states = states.select { |state| state[:position] == target.length }
        build_result(states)
      end

      private
      def normalize_types(types)
        result = {}
        types.each do |name, type|
          name = name.to_s
          names = Array(type).map do |value|
            key = value.to_s
            TYPE_ALIASES.fetch(key) do
              raise ArgumentError,
                "unsupported variable type: #{value.inspect}"
            end
          end.uniq
          result[name] = names
        end
        result
      end

      def tokens
        @tokens ||= begin
          result = []
          index = 0
          @template.pattern.scan(EXPRESSION) do
            expression_match = $~
            before = expression_match.pre_match
            if before.length > index
              result << { :literal => @template.pattern[index...before.length] }
              index = before.length
            end
            expression = expression_match[0]
            _, operator, varlist = *expression.match(EXPRESSION)
            specs = varlist.split(",").map do |varspec|
              _, name, modifier = *varspec.match(VARSPEC)
              @spec_index += 1
              {
                :name => name,
                :modifier => modifier,
                :key => "#{name}\0#{@spec_index}"
              }
            end
            specs.each do |spec|
              unless @types.key?(spec[:name])
                raise ArgumentError,
                  "missing type declaration for variable #{spec[:name].inspect}"
              end
              @prefix_ambiguity = true if spec[:modifier] =~ /^:\d+/
              @specs_by_key[spec[:key]] = spec
            end
            result << {
              :expression => expression,
              :operator => operator,
              :specs => specs
            }
            index = expression_match.end(0)
          end
          if index < @template.pattern.length
            result << { :literal => @template.pattern[index..-1] }
          end
          result
        end
      end

      def new_state
        {
          :position => 0,
          :mapping => {},
          :reasons => [],
          :infinite => false,
          :truncated => false
        }
      end

      def advance(state, amount)
        copy = state.dup
        copy[:position] += amount
        copy[:mapping] = state[:mapping].dup
        copy[:reasons] = state[:reasons].dup
        copy
      end

      def parse_expression(token, target, start)
        leader = LEADERS.fetch(token[:operator], "")
        absent = {
          :length => 0,
          :mapping => absent_mapping(token[:specs]),
          :reasons => [],
          :infinite => false,
          :truncated => false
        }
        results = [absent]
        if target[start, leader.length] == leader
          payload_start = start + leader.length
          parsed = if %w(; ? &).include?(token[:operator])
                     parse_form_expression(
                       token[:specs], target, payload_start, token[:operator]
                     )
                   else
                     parse_generic_expression(
                       token[:specs], target, payload_start, token[:operator]
                     )
                   end
          parsed.each do |candidate|
            candidate[:length] += leader.length
            results << candidate
          end
        end
        results
      end

      def absent_mapping(specs)
        specs.map { |spec| [spec[:key], nil] }.to_h
      end

      def merge_expression(state, expression)
        mapping = state[:mapping].dup
        expression[:mapping].each do |name, value|
          if mapping.key?(name)
            return nil unless mapping[name] == value
          else
            mapping[name] = value
          end
        end
        merged = state.dup
        merged[:position] = state[:position] + expression[:length]
        merged[:mapping] = mapping
        merged[:reasons] = (state[:reasons] + expression[:reasons]).uniq
        merged[:infinite] = state[:infinite] || expression[:infinite]
        merged[:truncated] = state[:truncated] || expression[:truncated]
        merged
      end

      def parse_generic_expression(specs, target, position, operator)
        parse_generic_vars(
          specs, 0, target, position, operator, false, false
        )
      end

      def parse_generic_vars(specs, index, target, position, operator,
                             seen_defined, leading_empty)
        options = []
        if index >= specs.length
          if !seen_defined || position == target.length
            options << { :length => 0, :mapping => {}, :reasons => [],
                         :infinite => false, :truncated => false }
          end
          return options
        end

        spec = specs[index]
        options.concat(parse_generic_absent(
          specs, index, target, position, operator,
          seen_defined, leading_empty
        ))
        @types[spec[:name]].each do |type|
          options.concat(parse_generic_defined(
            spec, type, specs, index, target, position, operator,
            seen_defined, leading_empty
          ))
        end
        options
      end

      def parse_generic_absent(specs, index, target, position, operator,
                               seen_defined, leading_empty)
        rest = parse_generic_vars(
          specs, index + 1, target, position, operator,
          seen_defined, leading_empty
        )
        rest.map do |candidate|
          candidate[:mapping] = { specs[index][:key] => nil }.merge(
            candidate[:mapping]
          )
          if position < target.length && !seen_defined &&
             @types[specs[index][:name]].include?(:scalar)
            candidate[:reasons] |= [empty_reason(specs[index][:name])]
          end
          candidate
        end
      end

      def parse_generic_defined(spec, type, specs, index, target, position,
                                operator, seen_defined, leading_empty)
        outer = generic_outer(operator)
        if type == :scalar
          parse_generic_scalar(
            spec, specs, index, target, position, operator,
            seen_defined, leading_empty, outer
          )
        elsif type == :list
          parse_generic_list(
            spec, specs, index, target, position, operator,
            seen_defined, leading_empty, outer
          )
        else
          parse_generic_map(
            spec, specs, index, target, position, operator,
            seen_defined, leading_empty, outer
          )
        end
      end

      def parse_generic_scalar(spec, specs, index, target, position, operator,
                               seen_defined, leading_empty, outer)
        if !seen_defined
          options = continue_empty_generic(
            spec, "", specs, index, target, position, operator,
            false, leading_empty
          )
          options.each do |candidate|
            candidate[:reasons] << empty_reason(spec[:name])
          end
        else
          options = []
        end

        prefix = prefix_length(spec)
        generic_scalar_end_positions(target, position, operator).each do |stop|
          raw = target[position...stop]
          next unless valid_raw?(raw, operator)
          value = decode(raw)
          next if value.nil?
          infinite = !prefix.nil? && value.length > prefix
          options.concat(continue_generic(
            { spec[:key] => value }, specs, index, target,
            position, stop, operator, true, leading_empty,
            infinite ? prefix_reason(spec[:name]) : nil, infinite
          ))
        end
        options
      end

      def generic_scalar_end_positions(target, position, operator)
        (position..target.length).to_a
      end

      def parse_generic_list(spec, specs, index, target, position, operator,
                             seen_defined, leading_empty, outer)
        options = []
        if !seen_defined
          empty = continue_empty_generic(
            spec, [], specs, index, target, position, operator,
            true, leading_empty
          )
          if @types[spec[:name]].include?(:scalar)
            empty.each { |candidate| candidate[:reasons] << empty_reason(spec[:name]) }
          end
          options.concat(empty)
        end
        positions = generic_part_end_positions(target, position, operator)
        if spec[:modifier] == "*"
          positions.each do |stop|
            list_partitions(
              target[position...stop], outer, operator
            ).each do |parts|
              decoded = parts.map { |value| decode(value) }
              next unless decoded.all? &&
                parts.all? { |value| valid_raw?(value, operator) }
              options.concat(continue_generic(
                { spec[:key] => decoded }, specs, index, target,
                position, stop, operator, true, leading_empty
              ))
            end
          end
        else
          positions.each do |stop|
            raw = target[position...stop]
            partitions = if reserved_operator?(operator)
                           list_partitions(raw, ",", operator)
                         else
                           values = split_raw(raw, ",")
                           values.all? { |value| valid_raw?(value, operator) } ?
                             [values] : []
                         end
            partitions.each do |values|
              decoded = values.map { |value| decode(value) }
              next unless decoded.all?
              options.concat(continue_generic(
                { spec[:key] => decoded }, specs, index, target,
                position, stop, operator, true, leading_empty
              ))
            end
          end
        end
        options
      end

      def parse_generic_map(spec, specs, index, target, position, operator,
                            seen_defined, leading_empty, outer)
        options = []
        if !seen_defined
          empty = continue_empty_generic(
            spec, {}, specs, index, target, position, operator,
            true, leading_empty
          )
          if @types[spec[:name]].include?(:scalar)
            empty.each { |candidate| candidate[:reasons] << empty_reason(spec[:name]) }
          end
          options.concat(empty)
        end
        positions = generic_part_end_positions(target, position, operator)
        if spec[:modifier] == "*"
          positions.each do |stop|
            map_pair_partitions(
              target[position...stop], outer, operator
            ).each do |pairs|
              pairs = pairs.map do |key, value|
                [decode(key), decode(value)]
              end
              next if pairs.any? { |key, value| key.nil? || value.nil? }
              mapping = pairs.to_h
              next if mapping.length != pairs.length
              options.concat(continue_generic(
                { spec[:key] => mapping }, specs, index, target,
                position, stop, operator, true, leading_empty
              ))
            end
          end
        else
          positions.each do |stop|
            raw = target[position...stop]
            mapping = if reserved_operator?(operator)
                        pairs = nonexplode_map_pair_partitions(
                          raw, ",", operator
                        )
                        next if pairs.empty?
                        options.concat(pairs.flat_map do |decoded_pairs|
                          continue_generic(
                            { spec[:key] => decoded_pairs.to_h }, specs, index,
                            target, position, stop, operator, true,
                            leading_empty
                          ).reject do |candidate|
                            decoded_pairs.to_h.length != decoded_pairs.length
                          end
                        end)
                        next
                      else
                        atoms = split_raw(raw, ",")
                        next if atoms.empty? || atoms.length.odd?
                        next unless atoms.all? { |atom|
                          valid_raw?(atom, operator)
                        }
                        values = atoms.map { |atom| decode(atom) }
                        next if values.any?(&:nil?)
                        pairs = values.each_slice(2).to_a
                        next if pairs.any? { |pair| pair.length != 2 }
                        result = pairs.to_h
                        next if result.length != pairs.length
                        result
                      end
            next if mapping.nil?
            options.concat(continue_generic(
              { spec[:key] => mapping }, specs, index, target,
              position, stop, operator, true, leading_empty
            ))
          end
        end
        options
      end

      def generic_part_end_positions(target, position, operator)
        (position..target.length).to_a
      end

      def continue_empty_generic(spec, value, specs, index, target, position,
                                 operator, seen_defined, leading_empty)
        options = continue_generic(
          { spec[:key] => value }, specs, index, target,
          position, position, operator, seen_defined, leading_empty
        )
        if !seen_defined && position < target.length &&
           target[position] == generic_outer(operator)
          options.concat(continue_generic(
            { spec[:key] => value }, specs, index, target,
            position, position + 1, operator, true, true, nil, false, true
          ))
        end
        options
      end

      def continue_generic(mapping, specs, index, target, start, stop,
                           operator, seen_defined, leading_empty,
                           reason = nil, infinite = false, consume_delimiter = nil)
        outer = generic_outer(operator)
        if index + 1 >= specs.length
          result = expression_candidate(
            stop - start, mapping, [reason].compact, infinite
          )
          return [result]
        end

        consume_delimiter = if !consume_delimiter.nil?
                              consume_delimiter
                            elsif seen_defined && stop < target.length &&
                                  target[stop] == outer
                              true
                            else
                              false
                            end
        next_position = stop + (consume_delimiter ? 1 : 0)
        rest = parse_generic_vars(
          specs, index + 1, target, next_position, operator,
          seen_defined, seen_defined
        )
        rest.map do |candidate|
          candidate[:length] += stop - start
          candidate[:length] += 1 if consume_delimiter
          candidate[:mapping] = mapping.merge(candidate[:mapping])
          candidate[:reasons] |= [reason].compact
          candidate[:infinite] ||= infinite
          candidate
        end
      end

      def generic_outer(operator)
        case operator
        when "/" then "/"
        when "." then "."
        else ","
        end
      end

      def reserved_operator?(operator)
        operator == "+" || operator == "#"
      end

      def parse_form_expression(specs, target, position, operator)
        parse_form_vars(specs, 0, target, position, operator, false)
      end

      def parse_form_vars(specs, index, target, position, operator,
                          seen_defined)
        options = []
        if index >= specs.length
          options << expression_candidate(0, {})
          return options
        end

        spec = specs[index]
        options.concat(parse_form_absent(
          specs, index, target, position, operator, seen_defined
        ))
        @types[spec[:name]].each do |type|
          options.concat(parse_form_defined(
            spec, type, specs, index, target, position,
            operator, seen_defined
          ))
        end
        options
      end

      def parse_form_absent(specs, index, target, position, operator,
                            seen_defined)
        parse_form_vars(
          specs, index + 1, target, position, operator, seen_defined
        ).map do |candidate|
          candidate[:mapping] = { specs[index][:key] => nil }.merge(
            candidate[:mapping]
          )
          if position < target.length && !seen_defined &&
             @types[specs[index][:name]].include?(:scalar)
            candidate[:reasons] |= [empty_reason(specs[index][:name])]
          end
          candidate
        end
      end

      def parse_form_defined(spec, type, specs, index, target, position,
                             operator, seen_defined)
        joiner = form_joiner(operator)
        if type == :scalar || (type == :list && spec[:modifier] != "*")
          parse_form_scalar_or_list(
            spec, type, specs, index, target, position,
            operator, joiner, seen_defined
          )
        elsif type == :list
          parse_form_explode_list(
            spec, specs, index, target, position,
            operator, joiner, seen_defined
          )
        else
          if spec[:modifier] == "*"
            parse_form_map(
              spec, specs, index, target, position,
              operator, joiner, seen_defined
            )
          else
            parse_form_nonexplode_map(
              spec, specs, index, target, position,
              operator, joiner, seen_defined
            )
          end
        end
      end

      def parse_form_scalar_or_list(spec, type, specs, index, target,
                                    position, operator, joiner, seen_defined)
        segment, stop = form_segment(target, position, joiner)
        return [] if segment.nil? || !segment.start_with?(spec[:name])

        body = segment[spec[:name].length..-1]
        return [] unless body.empty? || body.start_with?("=")
        raw_value = body.start_with?("=") ? body[1..-1] : ""
        return [] unless valid_form_raw?(raw_value)
        decoded_value = decode(raw_value)
        return [] if decoded_value.nil?

        value = decoded_value
        if type == :list
          raw_parts = raw_value.empty? ? [] : split_raw(raw_value, ",")
          return [] unless raw_parts.all? { |part| valid_form_raw?(part) }
          value = raw_parts.map { |part| decode(part) }
          return [] if value.any?(&:nil?)
        end

        prefix = prefix_length(spec)
        infinite = type == :scalar && !prefix.nil? &&
                   decoded_value.length > prefix
        reasons = []
        reasons << prefix_reason(spec[:name]) if infinite
        continue_form(
          { spec[:key] => value }, specs, index, target,
          position, stop, operator, joiner, true, reasons, infinite
        )
      end

      def parse_form_explode_list(spec, specs, index, target, position,
                                  operator, joiner, seen_defined)
        options = []
        if !seen_defined && position == target.length
          candidate = continue_form(
            { spec[:key] => [] }, specs, index, target,
            position, position, operator, joiner, true
          )
          if @types[spec[:name]].include?(:scalar)
            candidate.each { |entry| entry[:reasons] << empty_reason(spec[:name]) }
          end
          options.concat(candidate)
        end
        each_form_segment_end(target, position, joiner) do |segments, stop|
          matching = segments.take_while do |segment|
            segment.start_with?("#{spec[:name]}=")
          end
          next if matching.empty?
          values = matching.map do |segment|
            raw_value = segment[(spec[:name].length + 1)..-1]
            next nil unless valid_form_raw?(raw_value)
            decode(raw_value)
          end
          next if values.any?(&:nil?)
          consumed = matching.sum(0) { |part| part.length + joiner.length } -
                     joiner.length
          options.concat(continue_form(
            { spec[:key] => values }, specs, index, target,
            position, position + consumed, operator, joiner, true
          ))
        end
        options
      end

      def parse_form_map(spec, specs, index, target, position,
                         operator, joiner, seen_defined)
        options = []
        each_form_segment_end(target, position, joiner) do |segments, stop|
          next if segments.empty?
          values = segments.map do |segment|
            equals = segment.index("=")
            next nil unless equals
            raw_key = segment[0...equals]
            raw_value = segment[(equals + 1)..-1]
            next nil unless valid_form_raw?(raw_key) &&
                              valid_form_raw?(raw_value)
            [decode(raw_key), decode(raw_value)]
          end
          next if values.any?(&:nil?)
          mapping = values.to_h
          next if mapping.length != values.length
          options.concat(continue_form(
            { spec[:key] => mapping }, specs, index, target,
            position, stop, operator, joiner, true
          ))
        end
        options
      end

      def parse_form_nonexplode_map(spec, specs, index, target, position,
                                    operator, joiner, seen_defined)
        segment, stop = form_segment(target, position, joiner)
        return [] if segment.nil? || !segment.start_with?("#{spec[:name]}=")

        raw = segment[(spec[:name].length + 1)..-1]
        atoms = split_raw(raw, ",")
        return [] if atoms.empty? || atoms.length.odd?
        return [] unless atoms.all? { |atom| valid_form_raw?(atom) }
        values = atoms.map { |atom| decode(atom) }
        return [] if values.any?(&:nil?)
        pairs = values.each_slice(2).to_a
        mapping = pairs.to_h
        return [] if mapping.length != pairs.length
        continue_form(
          { spec[:key] => mapping }, specs, index, target,
          position, stop, operator, joiner, true
        )
      end

      def continue_form(mapping, specs, index, target, start, stop,
                        operator, joiner, seen_defined,
                        reasons = [], infinite = false)
        if index + 1 >= specs.length
          return [expression_candidate(
            stop - start, mapping, reasons, infinite
          )]
        end

        next_position = stop
        if next_position < target.length &&
           target[next_position] == joiner
          next_position += 1
        end
        rest = parse_form_vars(
          specs, index + 1, target, next_position, operator, seen_defined
        )
        rest.map do |candidate|
          candidate[:length] += stop - start
          candidate[:mapping] = mapping.merge(candidate[:mapping])
          candidate[:reasons] |= reasons
          candidate[:infinite] ||= infinite
          candidate
        end
      end

      def form_joiner(operator)
        operator == ";" ? ";" : "&"
      end

      def form_segment(target, position, joiner)
        stop = form_delimiter_positions(target, position, joiner).first ||
          target.length
        [target[position...stop], stop]
      end

      def each_form_segment_end(target, position, joiner)
        positions = form_delimiter_positions(target, position, joiner)
        positions.each do |stop|
          yield(split_raw(target[position...stop], joiner), stop)
        end
        yield(split_raw(target[position..-1], joiner), target.length)
      end

      def form_delimiter_positions(target, position, joiner)
        delimiter_positions(target[position..-1], joiner).map do |offset|
          position + offset
        end
      end

      def valid_form_raw?(raw)
        source = Addressable::URI::CharacterClasses::PCHAR + "/?"
        raw.match?(/\A(?:[#{source}]|%[a-fA-F0-9]{2})*\z/)
      end

      def expression_candidate(length, mapping, reasons = [], infinite = false)
        {
          :length => length,
          :mapping => mapping,
          :reasons => reasons.compact.uniq,
          :infinite => infinite,
          :truncated => false
        }
      end

      def prefix_length(spec)
        return nil unless spec[:modifier] =~ /^:\d+/
        spec[:modifier][1..-1].to_i
      end

      def empty_reason(name)
        { :reason => :empty_or_missing, :variable => name }
      end

      def prefix_reason(name)
        { :reason => :prefix_truncation, :variable => name }
      end

      def prefix_variables
        tokens.select { |token| token[:specs] }.flat_map { |token|
          token[:specs].select { |spec| spec[:modifier] =~ /^:\d+/ }
                       .map { |spec| spec[:name] }
        }.uniq
      end

      def decode(raw)
        return nil if raw.nil?
        Addressable::URI.unencode_component(raw)
      end

      def valid_raw?(raw, operator)
        source = case operator
                 when "+", "#"
                   Addressable::URI::CharacterClasses::RESERVED +
                     Addressable::URI::CharacterClasses::UNRESERVED
                 when "."
                   Addressable::URI::CharacterClasses::UNRESERVED
                     .gsub("\\.", "")
                 else
                   Addressable::URI::CharacterClasses::UNRESERVED
                 end
        raw.match?(/\A(?:[#{source}]|%[a-fA-F0-9]{2})*\z/)
      end

      def delimiter_positions(raw, delimiter)
        (0...raw.length).select do |position|
          raw[position] == delimiter && !encoded_position?(raw, position)
        end
      end

      def encoded_position?(raw, position)
        position >= 2 && raw[position - 2] == "%" &&
          raw[(position - 1), 2] =~ /\A[a-fA-F0-9]{2}\z/
      end

      def split_raw(raw, delimiter)
        positions = delimiter_positions(raw, delimiter)
        start = 0
        parts = positions.each_with_object([]) do |position, result|
          result << raw[start...position]
          start = position + 1
        end
        parts << raw[start..-1]
        parts
      end

      def split_at_positions(raw, positions)
        start = 0
        parts = positions.each_with_object([]) do |position, result|
          result << raw[start...position]
          start = position + 1
        end
        parts << raw[start..-1]
        parts
      end

      def list_partitions(raw, delimiter, operator)
        positions = delimiter_positions(raw, delimiter)
        cuts = reserved_operator?(operator) ?
          all_combinations(positions) : [positions]
        cuts.map { |chosen| split_at_positions(raw, chosen) }
            .select { |parts|
              parts.all? { |part| valid_raw?(part, operator) }
            }
      end

      def map_pair_partitions(raw, delimiter, operator)
        boundaries = if reserved_operator?(operator)
                       delimiter_positions(raw, delimiter) +
                         delimiter_positions(raw, "=")
                     else
                       delimiter_positions(raw, delimiter) +
                       delimiter_positions(raw, "=")
                     end.uniq.sort
        cuts = all_combinations(boundaries).select do |chosen|
          parts = split_at_positions(raw, chosen)
          parts.length.even? && parts.each_slice(2).all? do |key, value|
            key.include?("=")
          end
        end
        cuts.flat_map do |chosen|
          pair_options = split_at_positions(raw, chosen).map do |part|
            if reserved_operator?(operator)
              equal_positions(part, operator).map do |position|
                [part[0...position], part[(position + 1)..-1]]
              end.select do |key, value|
                valid_raw?(key, operator) && valid_raw?(value, operator)
              end
            else
              position = part.index("=")
              next [] unless position
              key = part[0...position]
              value = part[(position + 1)..-1]
              next [] unless valid_raw?(key, operator) &&
                              valid_raw?(value, operator)
              [[key, value]]
            end
          end
          next [] if pair_options.any?(&:empty?)
          cartesian(pair_options)
        end
      end

      def nonexplode_map_pair_partitions(raw, delimiter, operator)
        positions = delimiter_positions(raw, delimiter)
        cuts = if reserved_operator?(operator)
                 all_combinations(positions)
               else
                 [positions]
               end
        cuts.map do |chosen|
          parts = split_at_positions(raw, chosen)
          next unless parts.length.even?
          next unless parts.all? { |part| valid_raw?(part, operator) }
          decoded = parts.map { |part| decode(part) }
          next if decoded.any?(&:nil?)
          decoded.each_slice(2).to_a
        end.compact.uniq
      end

      def all_combinations(values)
        (0..values.length).flat_map do |count|
          values.combination(count).to_a
        end
      end

      def cartesian(values)
        values.inject([[]]) do |result, options|
          result.flat_map do |prefix|
            options.map { |option| prefix + [option] }
          end
        end
      end

      def equal_positions(raw, operator)
        if reserved_operator?(operator)
          return (0...raw.length).select do |position|
            raw[position] == "="
          end
        end
        raw.index("=") ? [raw.index("=")] : []
      end

      def prune_states(states)
        pruned = states.uniq { |state|
          [state[:position], state[:mapping], state[:reasons],
           state[:infinite], state[:truncated]]
        }
        pruned
      end

      def build_result(states)
        candidates = []
        prefix_states = {}
        reasons = []
        truncated = false

        states.each do |state|
          mapping = complete_mapping(state[:mapping])
          next unless mapping
          next unless verified?(mapping, target_of(mapping))
          reasons.concat(state[:reasons])
          if !candidates.include?(mapping)
            if @limit && candidates.length >= @limit
              truncated = true
              break
            end
            candidates << mapping
            prefix_states[mapping] = state if prefix_ambiguous?(mapping)
          end
        end

        infinite = @prefix_ambiguity && !candidates.empty?
        if infinite
          variables = prefix_variables_for(prefix_states.values)
          reasons << {
            :reason => :prefix_truncation,
            :variables => variables
          }
        end
        if candidates.size > 1
          reasons << { :reason => :multiple_candidates }
        end
        truncated = true if @limit && states.size > candidates.size &&
                            candidates.size >= @limit
        truncated ||= @limit == 0 && !states.empty?
        ambiguities = reasons.uniq

        CandidateSet.new(
          candidates,
          ambiguities,
          !infinite && !truncated,
          truncated
        )
      end

      def complete_mapping(mapping)
        result = {}
        @specs_by_key.values.each do |spec|
          value = mapping[spec[:key]]
          if result.key?(spec[:name])
            return nil unless result[spec[:name]] == value
          else
            result[spec[:name]] = value
          end
        end
        result
      end

      def prefix_ambiguous?(mapping)
        @specs_by_key.values.any? do |spec|
          length = prefix_length(spec)
          next false unless length
          value = mapping[spec[:name]]
          value.is_a?(String)
        end
      end

      def prefix_variables_for(states)
        state_reasons = states.flat_map { |state| state[:reasons] }
        prefixes = state_reasons.select do |reason|
          reason[:reason] == :prefix_truncation
        end.map { |reason| reason[:variable] }
        return prefixes unless prefixes.empty?
        prefix_variables
      end

      def target_of(mapping)
        @template.expand(
          mapping, nil, @normalize_values
        ).to_str
      end

      def verified?(mapping, expanded)
        expanded == @target
      end
    end

  end
end
