# frozen_string_literal: true

module Solargraph
  module Collection
    # Cacheable gem pins.
    #
    class Gem < Base
      include Logging

      attr_reader :metagem

      @@path_source_cache = {}

      # @param metagem [Metagem]
      def initialize metagem
        super()
        @metagem = metagem
      end

      def cache_file
        File.join CacheDir.gem_dir, "#{metagem.cache_name}.ser"
      end

      # Once a workspace's RBS collection has combined the gem's pins, its own
      # pins are released and later loads get the combined pins, e.g. the
      # catalogs that map path gems.
      #
      # @return [Array<Pin::Base>]
      def load
        return @@path_source_cache[metagem.full_path] ||= pins unless metagem.cacheable?
        combined_pins || super
      end

      def pins
        @pins ||= without_yard
      end

      def self.cached? metagem
        metagem.cacheable? && File.exist?(new(metagem).cache_file)
      end

      # Pin classes that only the mapping of their own file reads. Matched by
      # exact class: Closure subclasses CompoundStatement.
      UNREACHABLE = [Pin::CompoundStatement, Pin::While, Pin::Until].freeze

      # The gem pins a request can reach. Symbol pins only serve `:` symbol
      # completion, so symbols that appear only in gems are not offered there.
      # Block pins are only looked up by a location in the file being inferred,
      # which is never a gem file.
      #
      # @param pins [Array<Pin::Base>]
      # @return [Array<Pin::Base>]
      def self.reachable pins
        pins.reject do |pin|
          UNREACHABLE.include?(pin.class) || pin.is_a?(Pin::Symbol) || pin.is_a?(Pin::Block)
        end
      end

      # The gem's pins combined with RBS signatures, cached in place of its own
      # pins, so the pins the combination replaces are released.
      #
      # @param metagem [Metagem]
      # @param signatures [String] identifies the signatures in the cache key
      # @yieldreturn [Array<Pin::Base>] the signature pins
      # @return [Array<Pin::Base>]
      def self.combine metagem, signatures
        collection = new(metagem)
        Collection.cached("#{collection.cache_file}|#{signatures}") do
          own_pins = collection.load
          signature_pins = yield
          Collection.mem_cache.delete collection.cache_file
          signature_pins.empty? ? own_pins : RbsMap::Helpers.combine(own_pins, signature_pins)
        end
      end

      private

      # @return [Array<Pin::Base>, nil]
      def combined_pins
        prefix = "#{cache_file}|"
        key = Collection.mem_cache.keys.find { |cached| cached.start_with?(prefix) }
        Collection.mem_cache[key] if key
      end

      # Caches written before the unreachable pins were dropped still hold them.
      #
      # @return [Array<Pin::Base>, nil]
      def file_cache_pins
        pins = super
        return if pins.nil?
        Gem.reachable(pins)
      end

      def with_yard
        code_objects = Yardoc.load!(metagem)
        yard_pins = YardMap::Mapper.new(code_objects, metagem).map
        rbs_pins = RbsMap::Gem.pins(metagem)
        RbsMap::Helpers.combine(yard_pins, rbs_pins)
      end

      def without_yard
        files = metagem.require_paths.flat_map { |path| Dir.glob(File.join(metagem.full_path, path, '**', '*.rb')) }
        source_maps = files.map { |file| Solargraph::SourceMap.load(file) }

        # Generating an ApiMap is necessary for processing macros
        bench = Bench.new(source_maps: source_maps)
        source_pins = ApiMap.new.catalog(bench).pins.select { |pin| files.include?(pin.filename) }
        # After the catalog, whose macro expansion reads the nodes
        source_pins = Gem.reachable(source_pins)
        detach_nodes source_pins

        rbs_pins = RbsMap::Gem.pins(metagem)
        RbsMap::Helpers.combine(source_pins, rbs_pins)
      end

      # Detaches nodes from the pins and from every pin and chain they reach.
      # The pins can reach pins that are no longer in the list, e.g. the
      # parameters of a `module_function` copy close over the original method.
      #
      # @param pins [Array<Pin::Base>]
      # @return [void]
      def detach_nodes pins
        seen = {}.compare_by_identity
        # @type [::Array<Object>]
        stack = pins.dup
        until stack.empty?
          obj = stack.pop
          next if seen.key?(obj)
          seen[obj] = true
          case obj
          when Array then stack.concat(obj)
          when Pin::Base, Source::Chain, Source::Chain::Link
            # @sg-ignore Need to narrow a multi-class when
            obj.detach_nodes!
            obj.instance_variables.each { |ivar| stack.push obj.instance_variable_get(ivar) }
          end
        end
      end
    end
  end
end
