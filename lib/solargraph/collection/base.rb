# frozen_string_literal: true

require 'fileutils'

module Solargraph
  module Collection
    # The base class for cacheable pin collections. Subclasses need to
    # implement #pins and #cache_file.
    #
    # @!method pins
    #   The array of pins for this collection.
    #   @abstract
    #   @return [Array<Pin::Base>]
    # @!method cache_file
    #   The file that will store serialized pins.
    #   @abstract
    #   @return [String]
    class Base
      # Equal strings across all loaded caches share one frozen copy. Exact
      # String only: YARD::Docstring subclasses String.
      #
      # @param obj [Object]
      # @return [Object]
      def self.intern obj
        return obj unless obj.is_a?(String) && obj.instance_of?(String)
        -obj
      end

      # @return [Array<Pin::Base>]
      def load
        Collection.cached(cache_file) { file_cache_pins || generate_pin_caches }
      end

      # @return [Array<Pin::Base>]
      def self.load(...)
        new(...).load
      end

      def self.uncache(...)
        cache_file = new(...).cache_file
        FileUtils.rm_rf cache_file
        Collection.mem_cache.delete_if { |key, _| key == cache_file || key.start_with?("#{cache_file}|") }
      end

      private

      # @sg-ignore Marshal.load with a proc infers as Boolean
      # @return [Array<Pin::Base>, nil]
      def file_cache_pins
        return unless File.exist?(cache_file)
        Marshal.load(File.binread(cache_file), Base.method(:intern)) # rubocop:disable Security/MarshalLoad
      end

      def generate_pin_caches
        Collection.mem_cache[cache_file] = pins
        serial = Marshal.dump(pins)
        FileUtils.mkdir_p File.dirname(cache_file)
        File.write cache_file, serial, mode: 'wb'
        pins
      end
    end
  end
end
