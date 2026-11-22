# frozen_string_literal: true

module Solargraph
  class ApiMap
    # One layer of pins in a chain of indexes. Each layer catalogs only its own
    # pins; lookups read through the layers below it.
    #
    # Overrides apply in layer order: an override in a higher layer wins over
    # one in a lower layer for the same tag, wherever the overridden pin lives.
    # Within a layer, later override pins win.
    #
    class Index
      include Logging

      # Read-only view of one of the index hashes across a chain of layers.
      # Values found in several layers are concatenated bottom layer first.
      #
      # @generic T
      class View
        # @type [Array<generic<T>>]
        EMPTY = [].freeze

        # @param hashes [Array<Hash{String, nil => Array<generic<T>>}>] bottom layer first
        def initialize hashes
          @hashes = hashes.reject(&:empty?)
          # @type [Hash{String, nil => Array<generic<T>>}]
          @memo = {}
        end

        # @param key [String, nil]
        # @return [Array<generic<T>>]
        def [] key
          @memo.fetch(key) { lookup(key) }
        end

        # @param key [String, nil]
        def key? key
          @hashes.any? { |hash| hash.key?(key) }
        end

        # @return [Array<String, nil>]
        def keys
          return @hashes.first&.keys || [] if @hashes.length < 2

          @hashes.flat_map(&:keys).uniq
        end

        # @return [Integer]
        def size
          keys.size
        end

        private

        # @param key [String, nil]
        # @return [Array<generic<T>>]
        def lookup key
          found = nil
          combined = false
          @hashes.each do |hash|
            values = hash[key]
            next unless values

            if found.nil?
              found = values
            elsif combined
              found.concat values
            else
              found += values
              combined = true
            end
          end
          return EMPTY if found.nil?

          # @sg-ignore String, nil and String, NilClass do not unify
          @memo[key] = found if combined
          found
        end
      end

      # @return [Set<String>]
      attr_reader :macro_method_names

      # @return [Array<Pin::Base>] the pins of this layer alone
      attr_reader :own_pins

      # @return [Hash{String, nil => Array<Pin::Base>}]
      attr_reader :own_path_pin_hash

      # @return [Hash{String, nil => Array<Pin::Namespace>}]
      attr_reader :own_namespace_hash

      # @return [Hash{Class => Array<Pin::Base>}]
      attr_reader :own_pin_class_hash

      # @return [Hash{String, nil => Array<Pin::Reference::Include>}]
      attr_reader :own_include_references

      # @return [Hash{String, nil => Array<Pin::Reference::Extend>}]
      attr_reader :own_extend_references

      # @return [Hash{String, nil => Array<Pin::Reference::Prepend>}]
      attr_reader :own_prepend_references

      # @return [Hash{String, nil => Array<Pin::Reference::Superclass>}]
      attr_reader :own_superclass_references

      # @return [Hash{String, nil => Array<Pin::Reference::IncludedMixin>}]
      attr_reader :own_included_mixin_references

      # @return [Hash{String, nil => Array<Pin::FactoryParameter>}]
      attr_reader :own_factory_parameter_hash

      # @return [Hash{String, nil => Array<Pin::Method>}]
      attr_reader :own_macro_method_name_pins

      # @return [Hash{String => ComplexType}]
      attr_reader :own_alias_hash

      # @return [Array<Index>] bottom layer first, self last
      attr_reader :layers

      # @param pins [Enumerable<Pin::Base>]
      # @param parent [Index, nil] the layer below this one
      def initialize pins = [], parent = nil
        @parent = parent
        @layers = parent ? [*parent.layers, self] : [self]
        # @type [Hash{Class<Pin::Base> => Set<Pin::Base>}]
        @pin_select_cache = {}
        catalog pins
      end

      # @param pins [Enumerable<Pin::Base>]
      # @return [Index] a new layer on top of this one
      def merge pins
        Index.new(pins, self)
      end

      # @return [Array<Pin::Base>]
      def pins
        @pins ||= layers.length == 1 ? own_pins : layers.flat_map(&:own_pins)
      end

      # @return [Integer]
      def pin_count
        count = 0
        layers.each { |layer| count += layer.own_pins.length }
        count
      end

      # @return [View<Pin::Namespace>]
      def namespace_hash
        @namespace_hash ||= View.new(layers.map(&:own_namespace_hash))
      end

      # @return [View<Pin::Base>]
      def path_pin_hash
        @path_pin_hash ||= View.new(layers.map(&:own_path_pin_hash))
      end

      # @return [View<Pin::Reference::Include>]
      def include_references
        @include_references ||= View.new(layers.map(&:own_include_references))
      end

      # @return [View<Pin::Reference::Extend>]
      def extend_references
        @extend_references ||= View.new(layers.map(&:own_extend_references))
      end

      # @return [View<Pin::Reference::Prepend>]
      def prepend_references
        @prepend_references ||= View.new(layers.map(&:own_prepend_references))
      end

      # @return [View<Pin::Reference::Superclass>]
      def superclass_references
        @superclass_references ||= View.new(layers.map(&:own_superclass_references))
      end

      # @return [View<Pin::Reference::IncludedMixin>]
      def included_mixin_references
        @included_mixin_references ||= View.new(layers.map(&:own_included_mixin_references))
      end

      # @return [View<Pin::FactoryParameter>]
      def factory_parameter_hash
        @factory_parameter_hash ||= View.new(layers.map(&:own_factory_parameter_hash))
      end

      # @return [View<Pin::Method>]
      def macro_method_name_pins
        @macro_method_name_pins ||= View.new(layers.map(&:own_macro_method_name_pins))
      end

      # @return [Hash{String => ComplexType}]
      def alias_hash
        @alias_hash ||= begin
          # @type [Hash{String => ComplexType}]
          hash = {}
          layers.each { |layer| hash.merge!(layer.own_alias_hash) }
          hash
        end
      end

      # @generic T
      # @param klass [Class<generic<T>>]
      # @return [Set<generic<T>>]
      def pins_by_class klass
        @pin_select_cache[klass] ||= begin
          # @type [Set<generic<T>>]
          set = Set.new
          layers.each { |layer| set.merge(layer.own_pins_by_class(klass)) }
          set
        end
      end

      # @generic T
      # @param klass [Class<generic<T>>]
      # @return [Array<generic<T>>] the pins of this layer alone
      def own_pins_by_class klass
        result = []
        # @param key [Class]
        # @param pins [Array<Pin::Base>]
        own_pin_class_hash.each_pair { |key, pins| result.concat(pins) if key <= klass }
        result
      end

      private

      # @param new_pins [Enumerable<Pin::Base>]
      # @return [void]
      def catalog new_pins
        @own_pins = new_pins.to_a.dup
        set = own_pins.to_set
        @own_pin_class_hash = set.classify(&:class).transform_values(&:to_a)
        @own_namespace_hash = set.classify(&:namespace).transform_values(&:to_a)
        @own_path_pin_hash = set.classify(&:path).transform_values(&:to_a)
        @own_include_references = references(Pin::Reference::Include)
        @own_extend_references = references(Pin::Reference::Extend)
        @own_prepend_references = references(Pin::Reference::Prepend)
        @own_superclass_references = references(Pin::Reference::Superclass)
        @own_included_mixin_references = references(Pin::Reference::IncludedMixin)
        @own_factory_parameter_hash = own_pins_by_class(Pin::FactoryParameter).group_by(&:method_path)
        catalog_macros
        map_overrides
        @own_alias_hash = own_pins_by_class(Pin::Reference::TypeAlias).to_h { |pin| [pin.name, pin.return_type] }
      end

      # @generic T
      # @param klass [Class<generic<T>>]
      # @return [Hash{String, nil => Array<generic<T>>}]
      def references klass
        own_pins_by_class(klass).group_by(&:namespace)
      end

      # @return [void]
      def catalog_macros
        macro_pins = own_pins_by_class(Pin::Method).select { |pin| pin.macros.any? }
        @own_macro_method_name_pins = macro_pins.group_by(&:name)
        inherited = @parent&.macro_method_names || Set.new
        @macro_method_names = macro_pins.empty? ? inherited : inherited | macro_pins.map(&:name)
      end

      # Apply the overrides of the layers below to this layer's pins, then this
      # layer's overrides to the pins of every layer.
      #
      # @return [void]
      def map_overrides
        unless own_pins.empty?
          layers.take(layers.length - 1).each do |layer|
            layer.own_pins_by_class(Pin::Reference::Override).each do |ovr|
              targets = own_path_pin_hash[ovr.name]
              apply_override ovr, targets if targets
            end
          end
        end
        own_pins_by_class(Pin::Reference::Override).each do |ovr|
          apply_override ovr, path_pin_hash[ovr.name]
        end
      end

      # @param ovr [Pin::Reference::Override]
      # @param pins [Array<Pin::Base>]
      # @return [void]
      def apply_override ovr, pins
        pins.each do |pin|
          logger.debug { "ApiMap::Index#apply_override: applying #{ovr} to #{pin}" }
          new_pin = (path_pin_hash[pin.path.sub('#initialize', '.new')].first if pin.path.end_with?('#initialize'))
          (ovr.tags.map(&:tag_name) + ovr.delete).uniq.each do |tag|
            # @sg-ignore Wrong argument type for
            #   YARD::Docstring#delete_tags: name expected String,
            #   received String, Symbol - delete_tags is ok with a
            #   _ToS, but we should fix anyway
            pin.docstring.delete_tags tag
            new_pin&.docstring&.delete_tags tag
          end
          ovr.tags.each do |tag|
            pin.docstring.add_tag(tag)
            redefine_return_type pin, tag
            pin.reset_generated!

            next unless new_pin

            new_pin.docstring.add_tag(tag)
            redefine_return_type new_pin, tag
            new_pin.reset_generated!
          end
        end
      end

      # @param pin [Pin::Base]
      # @param tag [YARD::Tags::Tag]
      # @return [void]
      def redefine_return_type pin, tag
        # @todo can this be made to not mutate existing pins and use
        #   proxy() / proxy_with_signatures() instead?
        return unless pin && tag.tag_name == 'return'
        pin.instance_variable_set(:@return_type, ComplexType.try_parse(tag.type))
        # Only methods carry signatures; constants and other pins have
        # just the one return type set above.
        return unless pin.is_a?(Pin::Method)
        pin.signatures.each do |sig|
          sig.instance_variable_set(:@return_type, ComplexType.try_parse(tag.type))
        end
      end
    end
  end
end
