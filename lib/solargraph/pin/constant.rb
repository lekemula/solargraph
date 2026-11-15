# frozen_string_literal: true

module Solargraph
  module Pin
    class Constant < BaseVariable
      attr_reader :visibility

      # @param visibility [::Symbol] The visibility of the constant (:public, :protected, or :private)
      # @param alias_name [String, nil] The value of #alias_name kept after #detach_nodes!
      # @param splat [Hash] Additional options supported by superclasses
      def initialize visibility: :public, alias_name: nil, **splat
        super(**splat)
        @visibility = visibility
        @alias_name = alias_name
      end

      # The constant name the assigned value refers to, e.g. `Inner::Error`
      # for `Error = Inner::Error`
      #
      # @sg-ignore @alias_name is false once detached from a constant that is not an alias
      # @return [String, nil]
      def alias_name
        # false once detached from a constant that is not an alias
        return nil if @alias_name == false
        # @sg-ignore Need to add nil check here
        @alias_name || Parser::NodeMethods.unpack_name(assignment)
      end

      def detach_nodes! reload_from: nil
        @alias_name = alias_name || false
        super
      end

      def combine_with other, attrs = {}
        detached = other.detached_alias_name if other.is_a?(Constant)
        super(other, { alias_name: @alias_name || detached }.merge(attrs))
      end

      def return_type
        @return_type ||= generate_complex_type
      end

      def completion_item_kind
        Solargraph::LanguageServer::CompletionItemKinds::CONSTANT
      end

      # @return [Integer]
      def symbol_kind
        LanguageServer::SymbolKinds::CONSTANT
      end

      def path
        @path ||= context.namespace.to_s.empty? ? name : "#{context.namespace}::#{name}"
      end

      protected

      # @return [String, Boolean, nil]
      def detached_alias_name
        @alias_name
      end

      private

      # @return [ComplexType]
      def generate_complex_type
        tags = docstring.tags(:return).map(&:types).flatten.compact
        tags = docstring.tags(:type).map(&:types).flatten.compact if tags.empty?
        return ComplexType::UNDEFINED if tags.empty?
        ComplexType.try_parse(*tags)
      end
    end
  end
end
