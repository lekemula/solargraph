# frozen_string_literal: true

module Solargraph
  # The position of a Parser node in a workspace file, held by a pin in place
  # of the node itself. A node keeps its whole file's syntax tree and text
  # alive through its location, a reference keeps four values. The node is
  # parsed again on demand through the SourceCache.
  #
  class NodeRef
    # @return [String]
    attr_reader :filename

    # @return [Integer]
    attr_reader :begin_pos

    # @return [Integer]
    attr_reader :end_pos

    # @return [::Symbol]
    attr_reader :type

    # @param filename [String]
    # @param begin_pos [Integer]
    # @param end_pos [Integer]
    # @param type [::Symbol]
    def initialize filename, begin_pos, end_pos, type
      @filename = filename
      @begin_pos = begin_pos
      @end_pos = end_pos
      @type = type
    end

    # @return [::Parser::AST::Node, nil] nil if the file changed or cannot be read
    def node
      SourceCache.instance.node(self)
    end

    # @param root [::Parser::AST::Node, nil]
    # @return [::Parser::AST::Node, nil]
    def find_in root
      # @sg-ignore flow sensitive typing needs to handle is_a? in modifiers
      find_node(root) if root.is_a?(::Parser::AST::Node)
    end

    # @return [Array(String, Integer, Integer, ::Symbol)]
    def key
      [filename, begin_pos, end_pos, type]
    end

    # @param other [Object]
    def == other
      other.is_a?(NodeRef) && key == other.key
    end
    alias eql? ==

    def hash
      key.hash
    end

    def inspect
      "#<#{self.class.name} #{filename}[#{begin_pos}...#{end_pos}] #{type}>"
    end
    alias to_s inspect

    private

    # @param node [::Parser::AST::Node]
    # @return [::Parser::AST::Node, nil]
    def find_node node
      expr = NodeRef.expression(node)
      if expr
        return node if expr.begin_pos == begin_pos && expr.end_pos == end_pos && node.type == type
        return nil if expr.begin_pos > begin_pos || expr.end_pos < end_pos
      end
      node.children.each do |child|
        found = find_in(child)
        return found if found
      end
      nil
    end

    class << self
      # Detach a node from its pin.
      #
      # @param node [::Parser::AST::Node, NodeRef, nil]
      # @param filename [String, nil] The file the pin was mapped from. Nodes
      #   of that file become references, nodes of other sources and nodes
      #   without a location stay as they are. Without a filename the node is
      #   dropped.
      # @return [::Parser::AST::Node, NodeRef, nil]
      def detach node, filename
        return nil if filename.nil?
        # @sg-ignore flow sensitive typing needs to handle is_a? in modifiers
        located = position(node) if node.is_a?(::Parser::AST::Node)
        return node unless located && located.first == filename
        new(*located)
      end

      # @param value [::Parser::AST::Node, NodeRef, nil]
      # @return [::Parser::AST::Node, nil]
      def resolve value
        value.is_a?(NodeRef) ? value.node : value
      end

      # Compare two nodes, or references to them, without loading a node
      # that was detached: nodes compare by structure, references by position.
      #
      # @param left [::Parser::AST::Node, NodeRef, nil]
      # @param right [::Parser::AST::Node, NodeRef, nil]
      def same? left, right
        return left == right if left.is_a?(::Parser::AST::Node) && right.is_a?(::Parser::AST::Node)
        key(left) == key(right)
      end

      # A cache key for a node or reference that does not hold the node of a
      # named file, so a cache entry does not keep that file's text alive.
      #
      # @param value [::Parser::AST::Node, NodeRef, nil]
      # @return [Object]
      def key value
        return value.key if value.is_a?(NodeRef)
        return value unless value.is_a?(::Parser::AST::Node)
        # @sg-ignore flow sensitive typing needs to handle is_a? in guards
        position(value) || [value, value.location]
      end

      # @sg-ignore The parser gem does not type source maps
      # @param node [::Parser::AST::Node]
      # @return [::Parser::Source::Range, nil]
      def expression node
        node.loc&.expression
      end

      private

      # @param node [::Parser::AST::Node]
      # @return [Array(String, Integer, Integer, ::Symbol), nil] nil for a
      #   node without a location or from a source without a filename
      def position node
        expr = expression(node)
        return nil unless expr
        # @type [String, nil]
        name = expr.source_buffer.name
        return nil unless name
        [name, expr.begin_pos, expr.end_pos, node.type]
      end
    end
  end
end
