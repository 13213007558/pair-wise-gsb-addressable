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


require "addressable/uri"

module Addressable
  ##
  # This is an implementation of a URN parser based on
  # {RFC 8141}[https://www.rfc-editor.org/rfc/rfc8141.txt].
  #
  # A URN has the general structure:
  #
  #     "urn:" NID ":" NSS ["?+" r-component] ["?=" q-component]
  #        ["#" f-component]
  #
  # Addressable::URN is a subclass of Addressable::URI, so the generic URI
  # accessors continue to work: the NSS is exposed via #path, the
  # r/q-components via #query, and the f-component via #fragment.  In
  # addition, the dedicated accessors #nid, #nss, #r_component and
  # #q_component make the distinction between resolution parameters and
  # queries explicit.
  class URN < URI
    ##
    # Raised when a URN cannot be parsed or assigned invalid components.
    class InvalidURNError < InvalidURIError
    end

    ##
    # Container for the character classes specified in RFC 8141.
    module CharacterClasses
      NID = "a-zA-Z0-9\-"
      # pchar (RFC 3986) excludes "%"; add percent-encoding and "/".
      NSS = "#{URI::CharacterClasses::PCHAR}%\/".freeze
      RQ_COMPONENT = "#{NSS}\?".freeze
      F_COMPONENT = "#{URI::CharacterClasses::FRAGMENT}%".freeze
    end

    # RFC 8141 section 2.1: 2 to 32 alphanumeric or hyphen characters,
    # starting and ending with alphanumeric.
    NID_REGEX = /\A[a-zA-Z0-9][a-zA-Z0-9\-]{0,30}[a-zA-Z0-9]\z/
    NSS_REGEX = /\A[#{CharacterClasses::NSS}]+\z/
    RQ_COMPONENT_REGEX = /\A[#{CharacterClasses::RQ_COMPONENT}]+\z/
    F_COMPONENT_REGEX = /\A[#{CharacterClasses::F_COMPONENT}]*\z/
    PCT_TRIPLET_REGEX = /\A(?:[^%]|%[0-9A-Fa-f]{2})*\z/

    [NID_REGEX, NSS_REGEX, RQ_COMPONENT_REGEX, F_COMPONENT_REGEX,
      PCT_TRIPLET_REGEX].each(&:freeze)
    private_constant :NID_REGEX, :NSS_REGEX, :RQ_COMPONENT_REGEX,
      :F_COMPONENT_REGEX, :PCT_TRIPLET_REGEX

    ## The introducer for the r-component (resolution parameters).
    R_INTRODUCER = "?+".freeze
    ## The introducer for the q-component (resource query).
    Q_INTRODUCER = "?=".freeze
    ##
    # Registry of per-NID normalization rules.  Keys are lowercase NIDs;
    # values are callables receiving the URN and returning the normalized
    # NSS (as a String).  Unknown NIDs receive only the minimal processing
    # allowed by the RFC (percent-encoding case normalization).
    @namespace_rules = {}

    class << self
      ##
      # Registers a normalization rule for a namespace.
      #
      # @param [#to_str] nid The namespace identifier (case-insensitive).
      # @param [#call] callable An object responding to #call. It receives
      #   the Addressable::URN being normalized and must return the
      #   normalized NSS as a String.
      #
      # @return [Proc] The registered rule.
      #
      # @example
      #   Addressable::URN.register_namespace("isbn") do |urn|
      #     urn.nss.delete("-")
      #   end
      def register_namespace(nid, callable=nil, &block)
        rule = callable || block
        unless rule.respond_to?(:call)
          raise ArgumentError, "A callable rule or block is required."
        end
        nid = nid.to_s unless nid.respond_to?(:to_str)
        @namespace_rules[validate_nid_token!(nid.to_str)] = rule
      end

      ##
      # Removes a previously registered namespace normalization rule.
      #
      # @param [#to_str] nid The namespace identifier.
      # @return [Proc, nil] The removed rule, or nil if none was set.
      def unregister_namespace(nid)
        nid = nid.to_s unless nid.respond_to?(:to_str)
        @namespace_rules.delete(nid.to_str.downcase)
      end

      ##
      # @return [Hash] A copy of the registered namespace rules.
      def namespace_rules
        @namespace_rules.dup
      end

      ##
      # Returns a URN object based on the parsed string.
      #
      # @param [String, Addressable::URI, Addressable::URN, #to_str] urn
      #   The URN string to parse.
      #
      # @return [Addressable::URN] The parsed URN.
      #
      # @raise [Addressable::URN::InvalidURNError]
      #   Raised if the string is not a syntactically valid URN.
      def parse(urn)
        return nil unless urn
        return urn.dup if urn.kind_of?(self)

        if urn.kind_of?(::Addressable::URI) ||
            (urn.class.name =~ /^URI\b/ rescue false)
          urn = urn.to_s
        end

        unless urn.is_a?(String)
          begin
            urn = urn.to_str
          rescue TypeError, NoMethodError
            raise TypeError, "Can't convert #{urn.class} into String."
          end
        end

        assigned_name, f_component = split_fragment(urn)
        nid, nss, r_component, q_component =
          split_assigned_name(assigned_name)

        new(
          :scheme => "urn",
          :nid => nid,
          :nss => nss,
          :r_component => r_component,
          :q_component => q_component,
          :fragment => f_component
        )
      end

      # Splits a URN namestring into the assigned-name and f-component.
      # @api private
      def split_fragment(urn)
        assigned_name, separator, f_component = urn.partition("#")
        return assigned_name, nil if separator.empty?
        return assigned_name, f_component
      end

      # Splits the assigned-name into NID, NSS, r-component, q-component.
      # @api private
      def split_assigned_name(assigned_name)
        scheme, separator, remainder = assigned_name.partition(":")
        if separator.empty? || scheme.downcase != "urn"
          raise InvalidURNError,
            "Invalid URN scheme: '#{assigned_name}'"
        end

        nid, separator2, rest = remainder.partition(":")
        if separator2.empty?
          raise InvalidURNError,
            "Invalid URN, missing NSS separator: '#{assigned_name}'"
        end

        nss, r_component, q_component = split_rq(rest)
        return nid, nss, r_component, q_component
      end

      # Splits the NSS/r/q portion of a URN.  RFC 8141 places the
      # r-component ("?+") before the q-component ("?=").  The contents of
      # either component may include a literal "?", so delimiters are only
      # recognized between components, not within them.
      # @api private
      def split_rq(rest)
        r_component = nil
        q_component = nil
        # The NSS may not contain a literal "?" (it must be percent-encoded),
        # so the first "?+" or "?=" delimits the end of the NSS.
        r_index = rest.index(R_INTRODUCER)
        q_index = rest.index(Q_INTRODUCER)

        if r_index && (q_index.nil? || r_index < q_index)
          nss = rest[0...r_index]
          r_tail = rest[(r_index + R_INTRODUCER.length)...(q_index || rest.length)]
          r_component = r_tail
          if q_index
            q_component = rest[(q_index + Q_INTRODUCER.length)..-1]
          end
        elsif q_index
          nss = rest[0...q_index]
          q_component = rest[(q_index + Q_INTRODUCER.length)..-1]
        else
          nss = rest
        end
        return nss, r_component, q_component
      end

      # @api private
      def validate_nid_token!(token)
        nid = token.downcase
        if nid !~ NID_REGEX
          raise InvalidURNError, "Invalid NID: '#{token}'"
        end
        if nid == "urn"
          raise InvalidURNError, "NID may not be 'urn': '#{token}'"
        end
        nid
      end
    end
 
    ##
    # Creates a new URN from a set of component options.
    #
    # @option options [String] :nid The namespace identifier.
    # @option options [String] :nss The namespace-specific string.
    # @option options [String] :r_component The r-component.
    # @option options [String] :q_component The q-component.
    # @option options [String] :f_component The f-component (fragment).
    #
    # All generic URI options remain accepted for compatibility; a URN
    # must not carry an authority, however.
    def initialize(options={})
      options = options.dup
      nid = options.delete(:nid)
      nss = options.delete(:nss)
      r_component = options.delete(:r_component)
      q_component = options.delete(:q_component)
      f_component = options.delete(:f_component)

      if !nid.nil? || !nss.nil?
        if options.key?(:path)
          raise ArgumentError,
            "Cannot specify both a path and a NID/NSS."
        end
        options[:path] = compose_path(nid, nss)
      end
      if !r_component.nil? || !q_component.nil?
        if options.key?(:query)
          raise ArgumentError,
            "Cannot specify both a query and r/q-components."
        end
        options[:query] = compose_query(r_component, q_component)
      end
      if !f_component.nil?
        if options.key?(:fragment)
          raise ArgumentError,
            "Cannot specify both a fragment and an f-component."
        end
        options[:fragment] = f_component
      end
      if [nid, nss, r_component, q_component, f_component].any? { |v| !v.nil? } &&
          !options.key?(:scheme)
        options[:scheme] = "urn"
      end

      super(options)
    end

    ##
    # The namespace identifier for this URN (case-insensitively compared).
    #
    # @return [String] The NID.
    def nid
      parse_components unless @components_parsed
      @nid
    end

    ##
    # Sets the namespace identifier for this URN.
    #
    # @param [String, #to_str] new_nid The new NID.
    def nid=(new_nid)
      check_string!(:nid, new_nid)
      new_nid = new_nid.to_str
      self.class.send(:validate_nid_token!, new_nid)
      self.scheme = "urn" if self.scheme.nil?
      self.path = "#{new_nid}:#{self.nss}"
    end

    ##
    # The namespace-specific string for this URN.
    #
    # @return [String] The NSS.
    def nss
      parse_components unless @components_parsed
      @nss
    end

    ##
    # Sets the namespace-specific string for this URN.
    #
    # @param [String, #to_str] new_nss The new NSS.
    def nss=(new_nss)
      check_string!(:nss, new_nss)
      new_nss = new_nss.to_str
      if self.nid
        self.path = "#{self.nid}:#{new_nss}"
      else
        raise InvalidURNError, "Cannot set NSS without a NID."
      end
    end

    ##
    # The r-component (resolution parameters) for this URN.
    #
    # @return [String] The r-component, without the "?+" introducer.
    def r_component
      parse_components unless @components_parsed
      @r_component
    end
    alias r r_component

    ##
    # Sets the r-component.  Pass nil to remove it.
    #
    # @param [String, #to_str, nil] new_r_component The new r-component.
    def r_component=(new_r_component)
      if new_r_component.nil?
        self.query = compose_query(nil, self.q_component)
        return
      end
      check_string!(:r_component, new_r_component)
      new_r_component = new_r_component.to_str
      self.query = compose_query(new_r_component, self.q_component)
    end
    alias r= r_component=

    ##
    # The q-component (query against the resource) for this URN.
    #
    # @return [String] The q-component, without the "?=" introducer.
    def q_component
      parse_components unless @components_parsed
      @q_component
    end
    alias q q_component

    ##
    # Sets the q-component.  Pass nil to remove it.
    #
    # @param [String, #to_str, nil] new_q_component The new q-component.
    def q_component=(new_q_component)
      if new_q_component.nil?
        self.query = compose_query(self.r_component, nil)
        return
      end
      check_string!(:q_component, new_q_component)
      self.query = compose_query(self.r_component, new_q_component.to_str)
    end
    alias q= q_component=

    ##
    # The f-component (fragment) for this URN.
    #
    # @return [String] The f-component.
    def f_component
      self.fragment
    end
    alias f f_component

    ##
    # Sets the f-component.  Pass nil to remove it.
    #
    # @param [String, #to_str, nil] new_f_component The new f-component.
    def f_component=(new_f_component)
      self.fragment = new_f_component
    end
    alias f= f_component=

    ##
    # Converts the URN to a String.  Unlike a generic URI query, the URN
    # query component already carries its RFC 8141 introducer ("?+" or
    # "?="), so it is emitted verbatim rather than prefixed with another
    # "?".
    #
    # @return [String] The URN's String representation.
    def to_s
      @uri_string ||= begin
        uri_string = String.new
        uri_string << "#{self.scheme}:" if self.scheme != nil
        uri_string << self.path.to_s
        if self.query != nil
          query = self.query
          query = "#{query.start_with?("?") ? EMPTY_STR : "?"}#{query}"
          uri_string << query
        end
        uri_string << "##{self.fragment}" if self.fragment != nil
        uri_string.force_encoding(Encoding::UTF_8)
        uri_string
      end
    end
 
    ##
    # Sets the path component.  For URNs this is the "NID:NSS" portion.
    def path=(new_path)
      super
      parse_components
    end

    ##
    # Sets the generic query component.  For URNs this holds the
    # serialized r/q-components in canonical order.
    def query=(new_query)
      super
      parse_components
    end

    ##
    # The assigned-name, i.e. the URN without r/q/f-components.
    #
    # @return [String] The "urn:NID:NSS" portion.
    def assigned_name
      return nil if self.nid.nil?
      "urn:#{self.nid}:#{self.nss.to_s}"
    end

    ##
    # The normalized assigned-name.
    #
    # @return [String] The normalized "urn:NID:NSS" portion.
    def normalized_assigned_name
      return nil if self.nid.nil?
      "urn:#{self.normalized_nid}:#{self.normalized_nss}"
    end

    ##
    # The NID, normalized (always lowercase).
    #
    # @return [String] The normalized NID.
    def normalized_nid
      return nil unless self.nid
      self.nid.downcase
    end

    ##
    # The NSS, normalized.  Per RFC 8141 section 3, the NSS is never
    # case-folded wholesale: only the hex digits of percent-encoded
    # triplets are upcased, unless a registered NID rule says otherwise.
    #
    # @return [String] The normalized NSS.
    def normalized_nss
      return nil unless self.nss
      normalized = upcase_percent_encoding(self.nss)
      rule = namespace_rule(self.normalized_nid)
      if rule
        candidate = rule.call(self).to_str
        normalized = candidate
      end
      normalized
    end

    ##
    # The r-component, normalized (only percent-encoding case changes).
    #
    # @return [String] The normalized r-component.
    def normalized_r_component
      return nil unless self.r_component
      upcase_percent_encoding(self.r_component)
    end
    alias normalized_r normalized_r_component

    ##
    # The q-component, normalized (only percent-encoding case changes).
    #
    # @return [String] The normalized q-component.
    def normalized_q_component
      return nil unless self.q_component
      upcase_percent_encoding(self.q_component)
    end
    alias normalized_q normalized_q_component

    # @see Addressable::URI#normalized_path
    def normalized_path
      @normalized_path ||= begin
        if self.nid
          "#{self.normalized_nid}:#{self.normalized_nss}"
        else
          self.path.to_s
        end
      end
      force_utf8_encoding_if_needed(@normalized_path)
      @normalized_path
    end

    # @see Addressable::URI#normalized_query
    def normalized_query(*flags)
      return nil unless self.query
      parts = []
      # The stored query keeps the full RFC 8141 introducers.
      parts << "#{R_INTRODUCER}#{self.normalized_r_component}" if self.r_component
      parts << "#{Q_INTRODUCER}#{self.normalized_q_component}" if self.q_component
      parts.empty? ? nil : parts.join(EMPTY_STR)
    end

    # @see Addressable::URI#normalized_fragment
    def normalized_fragment
      return nil unless self.fragment
      upcase_percent_encoding(self.fragment)
    end

    ##
    # Returns a normalized URN object.  Unknown namespaces receive only the
    # minimal processing allowed by RFC 8141 (scheme/NID case and
    # percent-encoding case); registered namespaces use their own rules.
    #
    # @return [Addressable::URN] The normalized URN.
    def normalize
      return self.class.new if self.to_s.empty?
      self.class.new(
        :scheme => "urn",
        :nid => self.normalized_nid,
        :nss => self.normalized_nss,
        :r_component => self.normalized_r_component,
        :q_component => self.normalized_q_component,
        :fragment => self.normalized_fragment
      )
    end
 
    ##
    # Lexical equivalence comparison per RFC 8141 section 3.
    #
    # The r-component, q-component and f-component are excluded: they are
    # not part of the URN's resource identity.  Two URNs are lexically
    # equivalent when their normalized assigned-names are identical.
    #
    # @param [String, Addressable::URI, Addressable::URN] other
    #   The URN to compare against.
    #
    # @return [TrueClass, FalseClass]
    def lexically_equivalent?(other)
      other_urn = coerce_urn(other)
      return false unless other_urn
      return false unless self.nid && other_urn.nid
      self.normalized_assigned_name == other_urn.normalized_assigned_name
    end
    alias same_resource? lexically_equivalent?
    alias same_urn? lexically_equivalent?

    ##
    # Omits components from a URN.  In addition to the generic URI
    # component names, :r_component (or :r), :q_component (or :q) and
    # :f_component (or :f) are accepted.  NID and NSS cannot be omitted.
    def omit(*components)
      components = components.map do |component|
        case component
        when :r then :r_component
        when :q then :q_component
        when :f then :f_component
        else component
        end
      end
      known = [
        :scheme, :user, :password, :userinfo, :host, :port, :authority,
        :path, :query, :fragment,
        :r_component, :q_component, :f_component
      ]
      invalid = components - known
      unless invalid.empty?
        raise ArgumentError,
          "Invalid component names: #{invalid.inspect}."
      end
      if components.include?(:nid) || components.include?(:nss)
        raise ArgumentError, "NID and NSS cannot be omitted from a URN."
      end
      duplicated = self.dup
      duplicated.defer_validation do
        components.each do |component|
          case component
          when :r_component then duplicated.r_component = nil
          when :q_component then duplicated.q_component = nil
          when :f_component then duplicated.f_component = nil
          else duplicated.send("#{component}=", nil)
          end
        end
      end
      duplicated
    end

    # @api private
    def encode_with(coder)
      super
    end

  protected

    ##
    # Ensures that the URN is valid per RFC 8141.
    def validate
      super
      return if !!@validation_deferred
      return if self.to_s.empty?

      if self.scheme.nil? || self.scheme.downcase != "urn"
        raise InvalidURNError,
          "URN scheme must be 'urn': '#{self.to_s}'"
      end
      if self.authority
        raise InvalidURNError,
          "URN must not have an authority: '#{self.to_s}'"
      end

      parse_components
      # A scheme-only "urn:" shape is allowed as a transient/empty state,
      # but a populated path must contain both a valid NID and NSS.
      if !self.path.to_s.empty? && (@nid.nil? || @nss.to_s.empty?)
        raise InvalidURNError, "Invalid URN, missing NID or NSS: '#{self.to_s}'"
      end
      if @nid && !@nss.to_s.empty?
        self.class.send(:validate_nid_token!, @nid)
        validate_component!(@nss, NSS_REGEX, "NSS")
        validate_percent_triplets!(@nss, "NSS")
      end
      if @r_component
        validate_component!(@r_component, RQ_COMPONENT_REGEX, "r-component")
        validate_percent_triplets!(@r_component, "r-component")
      end
      if @q_component
        validate_component!(@q_component, RQ_COMPONENT_REGEX, "q-component")
        validate_percent_triplets!(@q_component, "q-component")
      end
      if self.fragment
        validate_component!(self.fragment, F_COMPONENT_REGEX, "f-component")
        validate_percent_triplets!(self.fragment, "f-component")
      end
      nil
    end

  private

    # Lazily derives NID, NSS, r/q-components from the generic path/query.
    def parse_components
      @nid = nil
      @nss = nil
      @r_component = nil
      @q_component = nil
      if self.path && self.path.include?(":")
        @nid, separator, rest = self.path.partition(":")
        if !separator.empty?
          @nss = rest
        else
          @nid = nil
        end
      end
      if self.query
        @r_component, @q_component =
          self.class.send(:parse_query_components, self.query)
      end
      @components_parsed = true
    end

    # Parses the query portion into r/q-components.  Two serializations are
    # accepted: the canonical URN form carrying the full RFC 8141
    # introducers ("?+" / "?="), and the form produced by a generic URI
    # parser, which strips the leading "?" (leaving "+" / "=").
    # Component content may include literal "?" characters, so the
    # component boundary is only the introducer itself.
    def self.parse_query_components(query)
      r_component = nil
      q_component = nil
      full_q = query.start_with?(Q_INTRODUCER)
      full_r = query.start_with?(R_INTRODUCER)
      if full_q
        q_component = query[Q_INTRODUCER.length..-1]
      elsif full_r
        tail = query[R_INTRODUCER.length..-1]
        q_index = tail.index(Q_INTRODUCER)
        if q_index
          r_component = tail[0...q_index]
          q_component = tail[(q_index + Q_INTRODUCER.length)..-1]
        else
          r_component = tail
        end
      elsif query.start_with?("+")
        # Generic-URI-compatible storage (the leading "?" was stripped).
        # The q-component boundary remains "?="; r-content may contain
        # bare "=" or "?" characters.
        tail = query[1..-1]
        q_index = tail.index(Q_INTRODUCER)
        if q_index
          r_component = tail[0...q_index]
          q_component = tail[(q_index + Q_INTRODUCER.length)..-1]
        else
          r_component = tail
        end
      elsif query.start_with?("=")
        q_component = query[1..-1]
      end
      [r_component, q_component]
    end

    def compose_path(nid, nss)
      return nil if nid.nil? && nss.nil?
      if nid.nil? || nss.nil?
        raise InvalidURNError, "Both NID and NSS are required."
      end
      check_string!(:nid, nid) unless nid.nil?
      check_string!(:nss, nss) unless nss.nil?
      "#{nid}:#{nss}"
    end

    def compose_query(r_component, q_component)
      query = EMPTY_STR.dup
      # Keep the full RFC 8141 introducers ("?+" / "?=") so that
      # component content containing literal "?=" or "=" round-trips
      # unambiguously.  #to_s emits the query verbatim for URNs.
      query << "#{R_INTRODUCER}#{r_component}" unless r_component.nil?
      query << "#{Q_INTRODUCER}#{q_component}" unless q_component.nil?
      query.empty? ? nil : query
    end

    def check_string!(name, value)
      return if value.respond_to?(:to_str)
      raise TypeError, "Can't convert #{value.class} into String (#{name})."
    end

    def validate_component!(value, regexp, label)
      unless value.is_a?(String) && value =~ regexp
        raise InvalidURNError, "Invalid #{label}: '#{value}'"
      end
    end

    def validate_percent_triplets!(value, label)
      unless value =~ PCT_TRIPLET_REGEX
        raise InvalidURNError,
          "Invalid percent-encoding in #{label}: '#{value}'"
      end
    end

    def namespace_rule(nid)
      self.class.instance_variable_get(:@namespace_rules)[nid]
    end

    # Minimal per-component normalization: uppercase percent-encoding hex.
    def upcase_percent_encoding(component)
      component.gsub(/%[0-9a-fA-F]{2}/, &:upcase)
    end

    def coerce_urn(other)
      case other
      when URN then other
      when ::Addressable::URI
        return nil unless other.scheme && other.scheme.downcase == "urn"
        begin
          URN.parse(other.to_s)
        rescue InvalidURNError
          nil
        end
      when String
        begin
          URN.parse(other)
        rescue InvalidURIError, TypeError
          nil
        end
      else
        if other.respond_to?(:to_str)
          coerce_urn(other.to_str)
        end
      end
    end
  end
end 
