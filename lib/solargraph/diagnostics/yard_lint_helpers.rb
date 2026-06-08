# frozen_string_literal: true

module Solargraph
  module Diagnostics
    # Utility methods for the yard-lint diagnostics reporter.
    #
    module YardLintHelpers
      module_function

      # Requires a specific version of yard-lint, or the latest installed
      # version if _version_ is `nil`.
      #
      # @param version [String, nil]
      # @raise [InvalidYardLintVersionError] if _version_ is not installed
      # @return [void]
      def require_yard_lint version = nil
        begin
          # @type [String]
          gem_path = Gem::Specification.find_by_name('yard-lint', version).full_gem_path
          gem_lib_path = File.join(gem_path, 'lib')
          # @sg-ignore Should better support meaning of '&' in RBS
          $LOAD_PATH.unshift(gem_lib_path) unless $LOAD_PATH.include?(gem_lib_path)
        rescue Gem::MissingSpecVersionError => e
          # @type [Array<Gem::Specification>]
          specs = e.specs
          raise InvalidYardLintVersionError,
                "could not find '#{e.name}' (#{e.requirement}) - " \
                "did find: [#{specs.map { |s| s.version.version }.join(', ')}]"
        end
        require 'yard-lint'
      end
    end
  end
end
