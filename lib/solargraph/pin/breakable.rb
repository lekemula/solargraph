# frozen_string_literal: true

module Solargraph
  module Pin
    # Mix-in for pins which enclose code which the 'break' statement
    # works with-in - e.g., blocks, when, until, ...
    module Breakable
      # @!method end_position
      #   @return [Position, nil]

      # @return [Location, nil]
      attr_reader :location
    end
  end
end
