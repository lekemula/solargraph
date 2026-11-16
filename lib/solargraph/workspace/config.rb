# frozen_string_literal: true

require 'yaml'

module Solargraph
  class Workspace
    # Configuration data for a workspace.
    #
    class Config
      # The maximum number of files that can be added to a workspace.
      # The workspace's .solargraph.yml can override this value.
      MAX_FILES = 5000

      GEM_LOADING_MODES = %w[all direct].freeze

      DEFAULT_GEM_LAZY_LOAD = 50

      # @return [String]
      attr_reader :directory

      # @todo Need to validate config
      # @return [Hash{String => undefined, nil}]
      attr_reader :raw_data

      # @param directory [String]
      def initialize directory = ''
        @directory = File.absolute_path(directory)
        @raw_data = config_data
        included
        excluded
      end

      # An array of files included in the workspace (before calculating excluded files).
      #
      # @return [Array<String>]
      def included
        return [] if directory.empty? || directory == '*'
        @included ||= process_globs(@raw_data['include'])
      end

      # An array of files excluded from the workspace.
      #
      # @return [Array<String>]
      def excluded
        return [] if directory.empty? || directory == '*'
        @excluded ||= process_exclusions(@raw_data['exclude'])
      end

      # @param filename [String]
      def allow? filename
        filename = File.absolute_path(filename, directory)
        filename.start_with?(directory) &&
          !excluded.include?(filename) &&
          excluded_directories.none? { |d| filename.start_with?(d) }
      end

      # The calculated array of (included - excluded) files in the workspace.
      #
      # @return [Array<String>]
      def calculated
        unless @calculated || directory.empty? || directory == '*'
          Solargraph.logger.info "Indexing workspace files in #{directory}"
        end
        @calculated ||= included - excluded
      end

      # An array of domains configured for the workspace.
      # A domain is a namespace that the ApiMap should include in the global
      # namespace. It's typically used to identify available DSLs.
      #
      # @return [Array<String>]
      # @sg-ignore Need to validate config
      def domains
        raw_data['domains']
      end

      # An array of required paths to add to the workspace.
      #
      # @return [Array<String>]
      # @sg-ignore Need to validate config
      def required
        raw_data['require']
      end

      # An array of load paths for required paths.
      #
      # @sg-ignore Need to validate config
      # @return [Array<String>]
      # @sg-ignore Need to validate config
      def require_paths
        raw_data['require_paths'] || []
      end

      # An array of reporters to use for diagnostics.
      #
      # @sg-ignore Need to validate config
      # @return [Array<String>]
      def reporters
        raw_data['reporters']
      end

      # A hash of options supported by the formatter
      #
      # @sg-ignore Need to validate config
      # @return [Hash]
      def formatter
        raw_data['formatter']
      end

      # An array of plugins to require.
      #
      # @sg-ignore Need to validate config
      # @return [Array<String>]
      def plugins
        raw_data['plugins']
      end

      # The maximum number of files to parse from the workspace.
      #
      # @sg-ignore Need to validate config
      # @return [Integer]
      def max_files
        raw_data['max_files']
      end

      # How many parsed sources of files that are not open the language server
      # keeps after it evicted them.
      #
      # @sg-ignore Need to validate config
      # @return [Integer]
      def source_cache_size
        raw_data['source_cache_size']
      end

      # Which gems to map: `all` maps every gem the workspace's requires
      # reach, with all of their dependencies; `direct` maps only the gems
      # the Gemfile declares itself. Gems that a workspace file, a convention
      # or a plugin requires are mapped in both modes.
      #
      # @return [String] `all` or `direct`
      def gem_loading
        gems = raw_data['gems']
        mode = gems.is_a?(Hash) ? gems['load'] : nil
        return 'all' if mode.nil?
        return mode if GEM_LOADING_MODES.include?(mode)

        Solargraph.logger.warn "Unknown gems.load #{mode.inspect} in #{workspace_config_path}, loading all gems"
        'all'
      end

      # Names of gems to map in every gem loading mode, e.g. a transitive
      # dependency that `direct` would skip.
      #
      # @return [Array<String>]
      def gem_includes
        gem_names_at('include')
      end

      # Names of gems never to map, however they are reached. Exclusion wins
      # over requires, plugins and `gem_includes`.
      #
      # @return [Array<String>]
      def gem_excludes
        gem_names_at('exclude')
      end

      # How many gems that `direct` skips may load when code first refers to
      # them, and stay loaded, least recently used first out. 0 turns it off.
      #
      # @return [Integer]
      def gem_lazy_load
        gems = raw_data['gems']
        limit = gems.is_a?(Hash) ? gems.fetch('lazy_load', DEFAULT_GEM_LAZY_LOAD) : DEFAULT_GEM_LAZY_LOAD
        return limit if limit.is_a?(Integer) && !limit.negative?

        Solargraph.logger.warn "gems.lazy_load in #{workspace_config_path} is not a count, loading no gems lazily"
        0
      end

      # @return [Hash{Symbol => Symbol}]
      def type_checker_rules
        # @type [Hash{String => String}]
        raw_rules = raw_data.fetch('type_checker', {}).fetch('rules', {})
        raw_rules.to_h do |k, v|
          [k.to_sym, v.to_sym]
        end
      end

      private

      # @return [String]
      def global_config_path
        ENV['SOLARGRAPH_GLOBAL_CONFIG'] ||
          File.join(Dir.home, '.config', 'solargraph', 'config.yml')
      end

      # @return [String]
      def workspace_config_path
        return '' if @directory.empty?
        File.join(@directory, '.solargraph.yml')
      end

      # @return [Hash{String => undefined}]
      def config_data
        workspace_config = read_config(workspace_config_path)
        global_config = read_config(global_config_path)

        defaults = default_config
        defaults.merge({ 'exclude' => [] }) unless workspace_config.nil?

        defaults
          .merge(global_config || {})
          .merge(workspace_config || {})
      end

      # Read a .solargraph yaml config
      #
      # @param config_path [String]
      # @return [Hash{String => Array, Hash, Integer}, nil]
      def read_config config_path = ''
        return nil if config_path.empty?
        return nil unless File.file?(config_path)
        YAML.safe_load_file(config_path)
      end

      # @param key [String]
      # @return [Array<String>]
      def gem_names_at key
        gems = raw_data['gems']
        names = gems.is_a?(Hash) ? gems[key] : nil
        return [] if names.nil?
        return names.map(&:to_s) if names.is_a?(Array)

        Solargraph.logger.warn "gems.#{key} in #{workspace_config_path} is not a list of gem names, ignoring it"
        []
      end

      # @return [Hash{String => Array, Hash, Integer}]
      def default_config
        {
          'include' => ['Rakefile', 'Gemfile', '*.gemspec', './**/*.rb'],
          'exclude' => ['spec/**/*', 'test/**/*', 'vendor/**/*', '.bundle/**/*'],
          'require' => [],
          'domains' => [],
          'reporters' => %w[rubocop require_not_found],
          'formatter' => {
            'rubocop' => {
              'cops' => 'safe',
              'except' => [],
              'only' => [],
              'extra_args' => []
            }
          },
          'type_checker' => {
            'rules' => {}
          },
          'require_paths' => [],
          'plugins' => [],
          'max_files' => MAX_FILES,
          'source_cache_size' => SourceCache::DEFAULT_SIZE,
          'gems' => { 'load' => 'all', 'include' => [], 'exclude' => [], 'lazy_load' => DEFAULT_GEM_LAZY_LOAD }
        }
      end

      # Get an array of files from the provided globs.
      #
      # @param globs [Array<String>]
      # @return [Array<String>]
      def process_globs globs
        globs.flat_map do |glob|
          Dir[File.absolute_path(glob, directory)]
            .map { |f| f.gsub('\\', '/') }
            .select { |f| File.file?(f) }
        end
      end

      # Modify the included files based on excluded directories and get an
      # array of additional files to exclude.
      #
      # @param globs [Array<String>]
      # @return [Array<String>]
      def process_exclusions globs
        remainder = globs.select do |glob|
          if glob_is_directory?(glob)
            exdir = File.absolute_path(glob_to_directory(glob), directory)
            included.delete_if { |file| file.start_with?(exdir) }
            false
          else
            true
          end
        end
        process_globs remainder
      end

      # True if the glob translates to a whole directory.
      #
      # @example
      #   glob_is_directory?('path/to/dir')       # => true
      #   glob_is_directory?('path/to/dir/**/*)   # => true
      #   glob_is_directory?('path/to/file.txt')  # => false
      #   glob_is_directory?('path/to/*.txt')     # => false
      #
      # @param glob [String]
      # @return [Boolean]
      def glob_is_directory? glob
        File.directory?(glob) || File.directory?(glob_to_directory(glob))
      end

      # Translate a glob to a base directory if applicable
      #
      # @example
      #   glob_to_directory('path/to/dir/**/*') # => 'path/to/dir'
      #
      # @param glob [String]
      # @return [String]
      def glob_to_directory glob
        glob.gsub(%r{(/\*|/\*\*/\*\*?)$}, '')
      end

      # @return [Array<String>]
      def excluded_directories
        # @type [Array<String>]
        excluded = @raw_data['exclude']
        excluded
          .select { |g| glob_is_directory?(g) }
          .map { |g| File.absolute_path(glob_to_directory(g), directory) }
      end
    end
  end
end
