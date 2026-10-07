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


begin
  require "addressable/idna/native"
rescue LoadError
  # libidn or the idn gem was not available, fall back on a pure-Ruby
  # implementation...
  require "addressable/idna/pure"
end

require "addressable/idna/uts46"

module Addressable
  module IDNA
    class << self
      alias_method :to_ascii_without_mode, :to_ascii
      alias_method :to_unicode_without_mode, :to_unicode

      # Converts a Unicode internationalized domain name to ASCII.
      #
      # @param [String] input The domain name to convert.
      # @param [Symbol] mode The IDNA mode: :idna2003 (the default,
      #   historical behavior) or :uts46 (UTS #46, Unicode IDNA
      #   Compatibility Processing, pinned to Unicode
      #   UTS46::UNICODE_VERSION).
      # @param [Hash] options When mode is :uts46, options are passed
      #   to UTS46.to_ascii (transitional:, use_std3_rules:,
      #   check_bidi:, check_joiners:, check_hyphens:,
      #   verify_dns_length:).
      def to_ascii(input, mode: :idna2003, **options)
        if mode == :uts46
          UTS46.to_ascii(input, **options)
        else
          to_ascii_without_mode(input)
        end
      end

      # Converts an ASCII domain name to Unicode. See #to_ascii for the
      # mode and options parameters.
      def to_unicode(input, mode: :idna2003, **options)
        if mode == :uts46
          UTS46.to_unicode(input, **options)
        else
          to_unicode_without_mode(input)
        end
      end
    end
  end
end
