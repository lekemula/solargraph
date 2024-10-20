# frozen_string_literal: true

module Solargraph
  class YardMap
    class Mapper
      autoload :ToMethod, 'solargraph/yard_map/mapper/to_method'
      autoload :ToNamespace, 'solargraph/yard_map/mapper/to_namespace'
      autoload :ToConstant, 'solargraph/yard_map/mapper/to_constant'

      # @param code_objects [Array<YARD::CodeObjects::Base>]
      # @param spec [Gem::Specification]
      # @param macro_code_objects [Array<YARD::CodeObjects::MacroObject]
      def initialize code_objects, spec = nil, macro_code_objects = []
        @code_objects = code_objects
        @spec = spec
        @pins = []
        @namespace_pins = {}
        # @param macro [YARD::CodeObjects::MacroObject]
        # @param hash [Hash{String => YARD::CodeObjects::MacroObject}]
        # @type [Hash{String => YARD::CodeObjects::MacroObject}]
        @macro_code_objects_by_path = macro_code_objects.each_with_object({}) do |macro, hash|
          hash[macro.method_object.path] = macro
        end
      end

      # @return [Array<Pin::Base>]
      def map
        @code_objects.each do |co|
          @pins.concat generate_pins co
        end
        # Some yardocs contain documentation for dependencies that can be
        # ignored here. The YardMap will load dependencies separately.
        @pins.keep_if { |pin| pin.location.nil? || File.file?(pin.location.filename) } if @spec
        @pins
      end

      private

      # @param code_object [YARD::CodeObjects::Base]
      # @return [Array<Pin::Base>]
      def generate_pins code_object
        result = []
        if code_object.is_a?(YARD::CodeObjects::NamespaceObject)
          nspin = ToNamespace.make(code_object, @spec, @namespace_pins[code_object.namespace.to_s])
          @namespace_pins[code_object.path] = nspin
          result.push nspin
          if code_object.is_a?(YARD::CodeObjects::ClassObject) and !code_object.superclass.nil?
            # This method of superclass detection is a bit of a hack. If
            # the superclass is a Proxy, it is assumed to be undefined in its
            # yardoc and converted to a fully qualified namespace.
            superclass = if code_object.superclass.is_a?(YARD::CodeObjects::Proxy)
              "::#{code_object.superclass}"
            else
              code_object.superclass.to_s
            end
            result.push Solargraph::Pin::Reference::Superclass.new(name: superclass, closure: nspin)
          end
          code_object.class_mixins.each do |m|
            result.push Solargraph::Pin::Reference::Extend.new(closure: nspin, name: m.path)
          end
          code_object.instance_mixins.each do |m|
            result.push Solargraph::Pin::Reference::Include.new(
              closure: nspin, # @todo Fix this
              name: m.path
            )
          end
        elsif code_object.is_a?(YARD::CodeObjects::MethodObject)
          require 'byebug'; byebug if !@macro_code_objects_by_path[code_object.path].nil?
          closure = @namespace_pins[code_object.namespace.to_s]
          if code_object.name == :initialize && code_object.scope == :instance
            # @todo Check the visibility of <Class>.new
            result.push ToMethod.make(code_object, 'new', :class, :public, closure, @spec)
            result.push ToMethod.make(code_object, 'initialize', :instance, :private, closure, @spec)
          else
            result.push ToMethod.make(code_object, nil, nil, nil, closure, @spec)
          end
        elsif code_object.is_a?(YARD::CodeObjects::ConstantObject)
          closure = @namespace_pins[code_object.namespace]
          result.push ToConstant.make(code_object, closure, @spec)
        elsif code_object.is_a?(YARD::CodeObjects::MacroObject)
          require 'byebug'; byebug if code_object.attached?
          # TODO: Handle gem macros
          # code_object.method_object.path
          # code_object.method_object.scope == :class
        end
        result
      end
    end
  end
end
