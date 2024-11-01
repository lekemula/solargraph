# frozen_string_literal: true

module Solargraph
  class YardMap
    # TODO: Move to DirectiveMapper
    class Mapper
      module FromMethodDirective
        module_function

        # @param source [Solargraph::Source]
        # @param pins [Array<Solargraph::Pin::Base>]
        # @param source_position [Position]
        # @param comment_position [Position]
        # @param directive [YARD::Tags::Directive]
        # @param code [String]
        # @param comments [String]
        # @return [Solargraph::Pin::Method]
        def make(source, pins, source_position, comment_position, directive, code, comments)
          namespace = closure_at(pins, source_position) || pins.first
          namespace = closure_at(pins, comment_position) if namespace.location.range.start.line < comment_position.line
          begin
            src = Solargraph::Source.load_string("def #{directive.tag.name};end", source.filename)
            region = Parser::Region.new(source: src, closure: namespace)
            gen_pin = Parser.process_node(src.node, region).first.last
            return if gen_pin.nil?
            # Move the location to the end of the line so it gets recognized
            # as originating from a comment
            shifted = Solargraph::Position.new(comment_position.line,
                                               code.lines[comment_position.line].to_s.chomp.length)
            # @todo: Smelly instance variable access
            gen_pin.instance_variable_set(:@comments, comments)
            gen_pin.instance_variable_set(:@location,
                                          Solargraph::Location.new(source.filename, Range.new(shifted, shifted)))
            gen_pin.instance_variable_set(:@explicit, false)
            gen_pin
          rescue Parser::SyntaxError => e
            # @todo Handle error in directive
          end
        end

        def closure_at(pins, position)
          pins.select { |pin| pin.is_a?(Pin::Closure) and pin.location.range.contain?(position) }.last
        end
      end
    end
  end
end
