# frozen_string_literal: true

module Solargraph
  class YardMap
    class Macro # rubocop:disable Style/Documentation
      class << self
        # @param directive [YARD::Tags::Handlers::Directive]
        # @param method_pin [Pin::Method]
        # @return [Macro]
        def from_directive(directive, method_pin)
          method_object = method_object_from_pin(method_pin)
          macro_object = YARD::CodeObjects::MacroObject.create(directive.tag.name, directive.tag.text, method_object)
          new(macro_object, directive, method_pin)
        end

        private

        # @param method_pin [Pin::Method]
        # @return [YARD::CodeObjects::MethodObject]
        def method_object_from_pin(method_pin)
          namespace_object = nil
          method_pin.each_closure do |namespace_pin|
            next if namespace_pin.name.empty?

            namespace_object = YARD::CodeObjects::NamespaceObject.new(
              namespace_object,
              namespace_pin.name.to_sym
            )
          end
          YARD::CodeObjects::MethodObject.new(namespace_object, method_pin.name)
        end
      end

      # @param macro [YARD::MacroObject]
      # @param method_pin [Pin::Method]
      # @param directive [YARD::Tags::Handlers::Directive]
      def initialize(macro, method_pin, directive)
        @macro = macro
        @method_pin = method_pin
        @directive = directive
      end

      # @return [String]
      def name
        @directive.tag.name
      end

      # @return [String]
      def text
        @directive.tag.text
      end
    end
  end
end
