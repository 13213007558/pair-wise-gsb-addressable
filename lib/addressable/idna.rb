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

module Addressable
  module IDNA
    class << self
      # The legacy (IDNA2003-compatible) conversions, kept as the
      # default. See Addressable::IDNA::UTS46 for the UTS 46 mode.
      alias_method :to_ascii_idna2003, :to_ascii
      alias_method :to_unicode_idna2003, :to_unicode
      private :to_ascii_idna2003, :to_unicode_idna2003
    end

    ##
    # Converts a Unicode domain name to ASCII.
    #
    # With the default +:idna2003+ mode this behaves exactly as it
    # always has. With +mode: :uts46+ the domain name is processed
    # according to Unicode IDNA Compatibility Processing (UTS #46)
    # using bundled Unicode 15.1.0 data; see
    # {Addressable::IDNA::UTS46.to_ascii} for the supported options.
    def self.to_ascii(input, mode: :idna2003, **options)
      case mode
      when :idna2003
        to_ascii_idna2003(input)
      when :uts46
        require "addressable/idna/uts46"
        UTS46.to_ascii(input, **options)
      else
        raise ArgumentError, "unknown IDNA mode: #{mode.inspect}"
      end
    end

    ##
    # Converts an ASCII domain name to Unicode.
    #
    # With the default +:idna2003+ mode this behaves exactly as it
    # always has. With +mode: :uts46+ the domain name is processed
    # according to Unicode IDNA Compatibility Processing (UTS #46)
    # using bundled Unicode 15.1.0 data; see
    # {Addressable::IDNA::UTS46.to_unicode} for the supported options.
    def self.to_unicode(input, mode: :idna2003, **options)
      case mode
      when :idna2003
        to_unicode_idna2003(input)
      when :uts46
        require "addressable/idna/uts46"
        UTS46.to_unicode(input, **options)
      else
        raise ArgumentError, "unknown IDNA mode: #{mode.inspect}"
      end
    end
  end
end
