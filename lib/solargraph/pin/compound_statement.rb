# frozen_string_literal: true

module Solargraph
  module Pin
    # A series of statements where if a given statement executes, /all
    # of the previous statements in the sequence must have executed as
    # well/.  In other words, the statements are run from the top in
    # sequence, until interrupted by something like a
    # return/break/next/raise/etc.
    #
    # This mix-in is used in flow sensitive typing to determine how
    # far we can assume a given assertion about a type can be trusted
    # to be true.
    #
    # Some examples in Ruby:
    #
    # * Bodies of methods and Ruby blocks
    # * Branches of conditionals and loops - if/elsif/else,
    #   unless/else, when, until, ||=, ?:, switch/case/else
    # * The body of begin-end/try/rescue/ensure statements
    #
    # Compare/contrast with:
    #
    # * Scope - a sequence where variables declared are not available
    #   after the end of the scope.  Note that this is not necessarily
    #   true for a compound statement.
    # * Compound statement - synonym
    # * Block - in Ruby this has a special meaning (a closure passed to a method), but
    #   in general parlance this is also a synonym.
    # * Closure - a sequence which is also a scope
    # * Namespace - a named sequence which is also a scope and a
    #   closure
    #
    # See:
    #   https://cse.buffalo.edu/~regan/cse305/RubyBNF.pdf
    #   https://ruby-doc.org/docs/ruby-doc-bundle/Manual/man-1.4/syntax.html
    #   https://en.wikipedia.org/wiki/Block_(programming)
    #
    # Note:
    #
    # Just because statement #1 in a sequence is executed, it doesn't
    # mean that future ones will.  Consider the effect of
    # break/next/return/raise/etc. on control flow.
    class CompoundStatement < Pin::Base
      # @param node [Parser::AST::Node, nil]
      # @param [Hash{Symbol => Object}] splat
      def initialize node: nil, **splat
        super(**splat)
        @node = node
        @end_position = nil
      end

      # @sg-ignore nil once the source changed on disk after eviction
      # @return [Parser::AST::Node]
      def node
        NodeRef.resolve(@node)
      end

      # Where the statement ends, for flow-sensitive typing
      #
      # @return [Position, nil]
      def end_position
        return @end_position if @end_position
        current = @node
        # @sg-ignore flow sensitive typing needs to handle is_a? in modifiers
        Position.new(current.loc.last_line, current.loc.last_column) if current.is_a?(::Parser::AST::Node)
      end

      def detach_nodes! reload_from: nil
        if reloads_node?
          @node = NodeRef.detach(@node, reload_from)
        else
          @end_position = end_position
          @node = nil
        end
        super
      end

      protected

      # @return [Parser::AST::Node, NodeRef, nil]
      def stored_node
        @node
      end

      private

      # True if the pin parses its node again after it was detached. Other
      # compound statements only keep their end position.
      def reloads_node?
        false
      end
    end
  end
end
