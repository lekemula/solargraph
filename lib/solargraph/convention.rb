# frozen_string_literal: true

require 'set'

module Solargraph
  # Conventions provide a way to modify an ApiMap based on expectations about
  # one of its sources.
  #
  module Convention
    autoload :Base,    'solargraph/convention/base'
    autoload :Gemfile, 'solargraph/convention/gemfile'
    autoload :Rspec,   'solargraph/convention/rspec'
    autoload :Gemspec, 'solargraph/convention/gemspec'
    autoload :Rakefile, 'solargraph/convention/rakefile'

    class << self
      def conventions
        @conventions ||= Set.new
      end

      # @param convention [Class<Convention::Base>]
      # @return [void]
      def register convention
        conventions.add convention.new
      end

      def clear_conventions
        conventions.clear
      end

      def register_defaults
        register Gemfile
        register Gemspec
        register Rspec
        register Rakefile
      end

      # @param source_map [SourceMap]
      # @return [Environ]
      def for_local(source_map)
        result = Environ.new
        conventions.each do |conv|
          result.merge conv.local(source_map)
        end
        result
      end

      # @param yard_map [YardMap]
      # @return [Environ]
      def for_global(yard_map)
        result = Environ.new
        conventions.each do |conv|
          result.merge conv.global(yard_map)
        end
        result
      end
    end

    register_defaults
  end
end
