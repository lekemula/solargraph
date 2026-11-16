# frozen_string_literal: true

module Solargraph
  # A collection of additional data, such as map pins and required paths, that
  # can be added to an ApiMap.
  #
  # Conventions are used to add Environs.
  #
  class Environ
    # @return [Array<String>]
    attr_reader :requires

    # Names of gems to map although they are only transitive dependencies,
    # which `gems.load: direct` would skip. They have no effect when all gems
    # are mapped, because transitive dependencies are mapped then anyway.
    # Unlike `requires`, these are gem names (e.g. `rspec-core`), not require
    # paths (e.g. `rspec/core`).
    #
    # @return [Array<String>]
    attr_reader :gem_names

    # @return [Array<String>]
    attr_reader :domains

    # @return [Array<Pin::Base>]
    attr_reader :pins

    # @return [Array<String>]
    attr_reader :yard_plugins

    # @param requires [Array<String>]
    # @param gem_names [Array<String>]
    # @param domains [Array<String>]
    # @param pins [Array<Pin::Base>]
    # @param yard_plugins [Array<String>]
    def initialize requires: [], gem_names: [], domains: [], pins: [], yard_plugins: []
      @requires = requires
      @gem_names = gem_names
      @domains = domains
      @pins = pins
      @yard_plugins = yard_plugins
    end

    # @return [self]
    def clear
      domains.clear
      requires.clear
      gem_names.clear
      pins.clear
      yard_plugins.clear
      self
    end

    # @param other [Environ]
    # @return [self]
    def merge other
      domains.concat other.domains
      requires.concat other.requires
      gem_names.concat other.gem_names
      pins.concat other.pins
      yard_plugins.concat other.yard_plugins
      self
    end
  end
end
