module Solargraph
  module Pin
    class Signature
      # @return [Array<Parameter>]
      attr_reader :parameters

      # @return [ComplexType]
      attr_reader :return_type

      # @return [Signature]
      attr_reader :block

      # @param parameters [Array<Parameter>]
      # @param return_type [ComplexType]
      # @param block [Signature]
      def initialize parameters, return_type, block = nil
        @parameters = parameters
        @return_type = return_type
        @block = block
      end

      def block?
        !!@block
      end

      # @param argcount [Integer]
      # @return [Boolean]
      def arguments_match?(argcount, with_block = false)
        parcount = parameters.length
        parcount -= 1 if !parameters.empty? && parameters.last.block?
        return false if block? && !with_block
        return false if argcount < parcount && !(argcount == parcount - 1 && parameters.last.restarg?)
        true
      end
    end
  end
end
