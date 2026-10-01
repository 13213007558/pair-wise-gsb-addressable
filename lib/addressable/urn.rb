# frozen_string_literal: true

require "addressable/uri"

module Addressable
  class URN < URI
    InvalidURNError = Class.new(InvalidURIError)

    NID_PATTERN = /\A(?:[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?|urn-[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?)\z/i
    PERCENT_ENCODING = /%[0-9a-fA-F]{2}/
    UNENCODED_PCHAR = /[A-Za-z0-9\-._~!$&'()*+,;=:@]/
    NSS_PATTERN = /\A(?:#{UNENCODED_PCHAR}|#{PERCENT_ENCODING})+\z/
    COMPONENT_PATTERN = /\A(?:#{UNENCODED_PCHAR}|\/|\?|#{PERCENT_ENCODING})*\z/

    @namespace_normalizers = {}

    class << self
      attr_reader :namespace_normalizers

      def register_namespace(nid, &normalizer)
        nid = convert_component(nid, "namespace identifier")
        validate_nid!(nid)
        if normalizer.nil?
          raise ArgumentError, "A namespace normalization block is required."
        end
        namespace_normalizers[nid.downcase] = normalizer
      end

      def parse(urn)
        return nil if urn.nil?
        return urn.dup if urn.kind_of?(self)
        if !urn.is_a?(String) && urn.class.name =~ /^URI\b/
          urn = urn.to_s
        end
        unless urn.is_a?(String)
          begin
            urn = urn.to_str
          rescue TypeError, NoMethodError
            raise TypeError, "Can't convert #{urn.class} into String."
          end
        end

        parsed = URI.send(:parse_uri_components, urn)
        unless parsed[:scheme] && parsed[:scheme].downcase == "urn"
          raise InvalidURNError, "URN scheme must be 'urn': #{urn.inspect}"
        end

        new(
          :path => parsed[:path],
          :query => parsed[:query],
          :fragment => parsed[:fragment]
        )
      end

      def convert_component(value, name)
        return value.to_str if value.respond_to?(:to_str)
        raise TypeError, "Can't convert #{value.class} into #{name}."
      end

      def validate_nid!(nid) # rubocop:disable Naming/PredicateName
        unless NID_PATTERN === nid
          raise InvalidURNError, "Invalid namespace identifier: #{nid.inspect}"
        end
      end

      def validate_component!(value, name) # rubocop:disable Naming/PredicateName
        unless COMPONENT_PATTERN === value && valid_percent_encoding?(value)
          raise InvalidURNError, "Invalid URN #{name}: #{value.inspect}"
        end
        if name == "fragment" && value.empty?
          raise InvalidURNError, "URN fragment cannot be empty."
        end
      end

      def valid_percent_encoding?(value)
        value.scan(/%[0-9a-fA-F]{0,2}/).all? do |sequence|
          sequence.length == 3
        end
      end

      private
    end

    def initialize(options={})
      if options.key?(:nid) || options.key?(:nss)
        if options.key?(:path)
          raise ArgumentError,
            "Cannot specify both a path and URN namespace components."
        end
        nid = options[:nid]
        nss = options[:nss]
        if nid.nil? || nss.nil?
          raise ArgumentError,
            "Both namespace identifier and namespace-specific string are required."
        end
        options = options.dup
        options[:path] = "#{nid}:#{nss}"
        options.delete(:nid)
        options.delete(:nss)
      end
      if options.key?(:r_component) || options.key?(:q_component)
        if options.key?(:query)
          raise ArgumentError,
            "Cannot specify both a query and URN resolution or query components."
        end
        r_component = options.delete(:r_component)
        q_component = options.delete(:q_component)
        options[:query] = build_urn_query(r_component, q_component)
      end

      if options[:scheme]
        unless options[:scheme].respond_to?(:to_str)
          raise TypeError,
            "Can't convert #{options[:scheme].class} into String."
        end
        unless options[:scheme].to_str.downcase == "urn"
          raise InvalidURNError, "URN scheme must be 'urn'."
        end
      end
      options[:scheme] = "urn"
      super(options)
      parse_components!
    end

    attr_reader :nid, :nss, :r_component, :q_component

    alias_method :set_path_without_urn_validation!, :path=
    private :set_path_without_urn_validation!

    def scheme=(new_scheme)
      if new_scheme && !new_scheme.respond_to?(:to_str)
        raise TypeError, "Can't convert #{new_scheme.class} into String."
      elsif new_scheme && new_scheme.to_str.downcase != "urn"
        raise InvalidURNError, "URN scheme must be 'urn'."
      end
      super(new_scheme.nil? ? nil : "urn")
    end

    def nid=(new_nid)
      new_nid = self.class.send(:convert_component, new_nid, "NID")
      self.class.send(:validate_nid!, new_nid)
      update_path("#{new_nid}:#{nss}")
    end

    def nss=(new_nss)
      new_nss = self.class.send(:convert_component, new_nss, "NSS")
      validate_nss!(new_nss)
      update_path("#{nid}:#{new_nss}")
    end

    def path=(new_path)
      if new_path && !new_path.respond_to?(:to_str)
        raise TypeError, "Can't convert #{new_path.class} into String."
      end
      update_path(new_path)
    end

    def r_component=(new_component)
      set_urn_component(:r_component, new_component)
    end

    def q_component=(new_component)
      set_urn_component(:q_component, new_component)
    end

    def query=(new_query)
      if new_query && !new_query.respond_to?(:to_str)
        raise TypeError, "Can't convert #{new_query.class} into String."
      end
      new_query = new_query.nil? ? nil : new_query.to_str
      unless @validation_deferred
        previous_query = @query
        begin
          @query = new_query
          parse_urn_query!
        rescue InvalidURNError
          @query = previous_query
          parse_urn_query!
          raise
        end
      end
      super(new_query)
      remove_composite_values
    end

    def fragment=(new_fragment)
      if new_fragment && !new_fragment.respond_to?(:to_str)
        raise TypeError, "Can't convert #{new_fragment.class} into String."
      end
      new_fragment = new_fragment.nil? ? nil : new_fragment.to_str
      unless new_fragment.nil?
        self.class.send(:validate_component!, new_fragment, "fragment")
      end
      previous_fragment = @fragment
      super
      remove_composite_values
    rescue InvalidURNError
      @fragment = previous_fragment
      remove_composite_values
      raise
    end

    def normalized_nid
      return nil unless nid
      @normalized_nid = nid.downcase if @normalized_nid == NONE
      @normalized_nid
    end

    def normalized_nss
      return nil unless nss
      if @normalized_nss == NONE
        normalized = normalize_percent_encoding(nss)
        normalizer = self.class.namespace_normalizers[normalized_nid]
        normalized = normalizer.call(normalized) if normalizer
        @normalized_nss = normalized
      end
      @normalized_nss
    end

    def normalized_r_component
      return nil unless r_component
      @normalized_r_component ||= normalize_urn_component(r_component)
    end

    def normalized_q_component
      return nil unless q_component
      @normalized_q_component ||= normalize_urn_component(q_component)
    end

    def normalized_query(*)
      return nil unless query
      @normalized_query = build_urn_query(
        normalized_r_component, normalized_q_component
      ) unless @normalized_query.is_a?(String)
      force_utf8_encoding_if_needed(@normalized_query)
      @normalized_query
    end

    def normalized_path
      @normalized_path ||= "#{normalized_nid}:#{normalized_nss}"
    end

    def normalized_fragment
      return nil unless fragment
      @normalized_fragment = normalize_urn_component(fragment) unless @normalized_fragment.is_a?(String)
      @normalized_fragment
    end

    def lexically_equivalent?(other)
      other = URN.parse(other) unless other.kind_of?(URN)
      normalize.to_s == other.normalize.to_s
    rescue InvalidURIError, TypeError
      false
    end
    alias_method :equivalent?, :lexically_equivalent?

    def resource_identifier
      "urn:#{normalized_nid}:#{normalized_nss}"
    end

    def same_resource?(other)
      other = URN.parse(other) unless other.kind_of?(URN)
      resource_identifier == other.resource_identifier
    rescue InvalidURIError, TypeError
      false
    end

    def to_hash
      hash = super
      hash.delete(:user)
      hash.delete(:password)
      hash.delete(:host)
      hash.delete(:port)
      hash[:nid] = nid
      hash[:nss] = nss
      hash[:r_component] = r_component
      hash[:q_component] = q_component
      hash
    end

    def to_s
      @uri_string ||= begin
        urn_string = "#{scheme}:#{path}"
        urn_string << serialized_urn_query
        urn_string << "##{fragment}" if fragment
        urn_string.force_encoding(Encoding::UTF_8)
        urn_string
      end
    end

    private

    def parse_components!
      return if @validation_deferred
      unless @scheme && @scheme.downcase == "urn"
        raise InvalidURNError, "URN scheme must be 'urn'."
      end
      if @path.nil?
        raise InvalidURNError, "URN namespace identifier is missing."
      end
      separator = @path.index(":")
      if separator.nil? || separator.zero?
        raise InvalidURNError, "URN namespace identifier is missing: #{@path.inspect}"
      end
      @nid = @path[0...separator]
      @nss = @path[(separator + 1)..-1]
      self.class.send(:validate_nid!, @nid)
      validate_nss!(@nss)
      @normalized_nid = NONE
      @normalized_nss = NONE
      @normalized_path = nil
      parse_urn_query!
      validate_fragment!(@fragment)
    end

    def update_path(new_path)
      previous_path = @path
      set_path_without_urn_validation!(new_path)
      parse_components!
      remove_composite_values
    rescue InvalidURNError
      @path = previous_path
      parse_components!
      remove_composite_values
      raise
    end

    def parse_urn_query!
      @r_component = nil
      @q_component = nil
      @normalized_r_component = nil
      @normalized_q_component = nil
      @normalized_query = NONE
      return if @query.nil?

      remainder = @query
      if remainder.start_with?("+")
        remainder = remainder[1..-1]
        delimiter = remainder.index("?=")
        if delimiter
          @r_component = remainder[0...delimiter]
          @q_component = remainder[(delimiter + 2)..-1]
        else
          @r_component = remainder
        end
      elsif remainder.start_with?("=")
        @q_component = remainder[1..-1]
      else
        raise InvalidURNError,
          "URN query must begin with '?+' or '?=': #{@query.inspect}"
      end
      validate_urn_component!(@r_component, "r-component") unless @r_component.nil?
      validate_urn_component!(@q_component, "q-component") unless @q_component.nil?
    end

    def set_urn_component(name, value)
      if value && !value.respond_to?(:to_str)
        raise TypeError, "Can't convert #{value.class} into String."
      end
      value = value.nil? ? nil : value.to_str
      if value
        self.class.send(:validate_component!, value, "#{name.to_s.tr('_', '-')}")
      end
      previous_components = [@query, @r_component, @q_component]
      instance_variable_set("@#{name}", value)
      new_query = build_urn_query(@r_component, @q_component)
      begin
        @query = new_query
        parse_urn_query!
        remove_composite_values
      rescue InvalidURNError
        @query, @r_component, @q_component = previous_components
        remove_composite_values
        raise
      end
    end

    def build_urn_query(r_component, q_component)
      return nil if r_component.nil? && q_component.nil?
      query = String.new
      query << "+#{r_component}" if r_component
      query << "?=#{q_component}" if r_component && q_component
      query << "=#{q_component}" if r_component.nil? && q_component
      query
    end

    def serialized_urn_query
      return EMPTY_STR if @query.nil?
      "?#{@query}"
    end

    def validate_nss!(value)
      unless value && NSS_PATTERN === value &&
          self.class.send(:valid_percent_encoding?, value)
        raise InvalidURNError,
          "Invalid namespace-specific string: #{value.inspect}"
      end
    end

    def validate_fragment!(value)
      return if value.nil?
      return if @validation_deferred
      self.class.send(:validate_component!, value, "fragment")
    end

    def validate_urn_component!(value, name)
      self.class.send(:validate_component!, value, name)
    end

    def normalize_percent_encoding(value)
      value.gsub(/%([0-9a-fA-F]{2})/) do |sequence|
        byte = $1.to_i(16)
        if (0x41..0x5a).include?(byte) ||
            (0x61..0x7a).include?(byte) ||
            (0x30..0x39).include?(byte) ||
            "-._~".bytes.include?(byte)
          byte.chr
        else
          "%#{$1.upcase}"
        end
      end
    end

    def normalize_urn_component(value)
      normalize_percent_encoding(value)
    end

    def validate
      super
      parse_components!
    rescue InvalidURNError
      raise unless @validation_deferred
    end

    def reset_ivs
      super
      @nid = nil
      @nss = nil
      @r_component = nil
      @q_component = nil
      @normalized_nid = NONE
      @normalized_nss = NONE
      @normalized_r_component = nil
      @normalized_q_component = nil
    end

    def replace_self(uri)
      super
      parse_components!
      self
    end
  end
end
