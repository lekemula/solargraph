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

      def load
        return super if metagem.cacheable?
        @@path_source_cache[metagem.full_path] ||= pins
      end

      def pins
        @pins ||= without_yard
      end

      def self.cached? metagem
        metagem.cacheable? && File.exist?(new(metagem).cache_file)
      end

      private

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
