# frozen_string_literal: true

require 'open3'
require 'json'

module Solargraph
  # A workspace consists of the files in a project's directory and the
  # project's configuration. It provides a Source for each file to be used
  # in an associated Library or ApiMap.
  #
  class Workspace
    autoload :Config, 'solargraph/workspace/config'
    autoload :RequirePaths, 'solargraph/workspace/require_paths'

    # @return [String]
    attr_reader :directory

    # @return [Array<String>]
    attr_reader :gemnames
    alias source_gems gemnames

    # Changes whenever a file is added to or removed from the workspace.
    #
    # @return [Integer]
    attr_reader :generation

    # @param directory [String] TODO: Remove '' and '*' special cases
    # @param config [Config, nil]
    # @param server [Hash]
    def initialize directory = '', config = nil, server = {}
      raise ArgumentError, 'directory must be a String' unless directory.is_a?(String)

      @directory = if ['*', ''].include?(directory)
                     directory
                   else
                     File.absolute_path(directory)
                   end
      @config = config
      @server = server
      @generation = 0
      load_sources
      @gemnames = []
      require_plugins
    end

    # The require paths associated with the workspace.
    #
    # @return [Array<String>]
    def require_paths
      # @todo are the semantics of '*' the same as '', meaning 'don't send back any require paths'?
      @require_paths ||= RequirePaths.new(directory_or_nil, config).generate
    end

    # @return [Solargraph::Workspace::Config]
    def config
      @config ||= Solargraph::Workspace::Config.new(directory)
    end

    # @param level [Symbol]
    # @return [TypeChecker::Rules]
    def rules level
      @rules ||= TypeChecker::Rules.new(level, config.type_checker_rules)
    end

    # Merge the source. A merge will update the existing source for the file
    # or add it to the sources if the workspace is configured to include it.
    # The source is ignored if the configuration excludes it.
    #
    # @param sources [Array<Solargraph::Source>]
    # @return [Boolean] True if the source was added to the workspace
    def merge *sources
      unless directory == '*' || sources.all? { |source| source_hash.key?(source.filename) }
        # Reload the config to determine if a new source should be included
        @config = Solargraph::Workspace::Config.new(directory)
      end

      includes_any = false
      sources.each do |source|
        next unless directory == '*' || config.calculated.include?(source.filename)

        @generation = @generation.next unless source_hash.key?(source.filename)
        # @sg-ignore Wrong argument type for Hash#[]=: arg0 expected String, received String, nil
        source_hash[source.filename] = source
        includes_any = true
      end

      includes_any
    end

    # Remove a source from the workspace. The source will not be removed if
    # its file exists and the workspace is configured to include it.
    #
    # @param filename [String]
    # @return [Boolean] True if the source was removed from the workspace
    def remove filename
      return false unless source_hash.key?(filename)
      source_hash.delete filename
      @generation = @generation.next
      true
    end

    # @return [Array<String>]
    def filenames
      source_hash.keys
    end

    # Every source of the workspace. Evicted sources get loaded again, one
    # by one through the SourceCache.
    #
    # @return [Enumerator<Solargraph::Source>]
    def sources
      Enumerator.new do |yielder|
        filenames.each do |filename|
          found = source(filename)
          yielder << found if found
        end
      end
    end

    # @param filename [String]
    # @return [Boolean]
    def has_file? filename
      source_hash.key?(filename)
    end

    # Get a source by its filename.
    #
    # @sg-ignore flow sensitive typing needs to handle unless in guards
    # @param filename [String]
    # @return [Solargraph::Source, nil] nil if the file is evicted and changed
    #   on disk since it was mapped
    def source filename
      resident = source_hash[filename]
      return resident if resident
      return nil unless source_hash.key?(filename)
      SourceCache.instance.fetch(filename)
    end

    # Drop a source's text after its file was mapped. The file stays in the
    # workspace.
    #
    # @param filename [String]
    # @return [void]
    def evict filename
      source_hash[filename] = nil if source_hash.key?(filename)
    end

    # @param filename [String]
    def evicted? filename
      source_hash.key?(filename) && source_hash[filename].nil?
    end

    # True if the path resolves to a file in the workspace's require paths.
    #
    # @param path [String]
    # @return [Boolean]
    def would_require? path
      require_paths.each do |rp|
        full = File.join rp, path
        return true if File.file?(full) || File.file?(full << '.rb')
      end
      false
    end

    # @return [String, nil]
    def rbs_collection_path
      @rbs_collection_path ||= read_rbs_collection_path
    end

    # @return [String, nil]
    def rbs_collection_config_path
      @rbs_collection_config_path ||= unless directory.empty? || directory == '*'
                                        yaml_file = File.join(directory, 'rbs_collection.yaml')
                                        yaml_file if File.file?(yaml_file)
                                      end
    end

    # @param name [String]
    # @param version [String, nil]
    # @param out [IO, nil]
    #
    # @return [Gem::Specification, nil]
    def find_gem name, version = nil, out: nil
      Gem::Specification.find_by_name(name, version)
    end

    # Synchronize the workspace from the provided updater.
    #
    # @param updater [Source::Updater]
    # @return [void]
    def synchronize! updater
      @generation = @generation.next unless source_hash.key?(updater.filename)
      # @sg-ignore Need to add nil check here
      source_hash[updater.filename] = source(updater.filename).synchronize(updater)
    end

    # @sg-ignore return type could not be inferred
    # @return [String]
    def command_path
      server['commandPath'] || 'solargraph'
    end

    # @return [String, nil]
    def directory_or_nil
      return nil if directory.empty? || directory == '*'
      directory
    end

    # True if the workspace has a root Gemfile.
    #
    # @todo Handle projects with custom Bundler/Gemfile setups (see DocMap#gemspecs_required_from_bundler)
    #
    def gemfile?
      directory && File.file?(File.join(directory, 'Gemfile'))
    end

    # True if the workspace contains at least one gemspec file.
    #
    # @return [Boolean]
    def gemspec?
      !gemspec_files.empty?
    end

    # Get an array of all gemspec files in the workspace.
    #
    # @return [Array<String>]
    def gemspec_files
      return [] if directory.empty? || directory == '*'
      @gemspec_files ||= Dir[File.join(directory, '**/*.gemspec')].select do |gs|
        config.allow? gs
      end
    end

    private

    # The language server configuration (or an empty hash if the workspace was
    # not initialized from a server).
    #
    # @return [Hash]
    attr_reader :server

    # @return [Hash{String => Solargraph::Source, nil}] nil for an evicted source
    def source_hash
      @source_hash ||= {}
    end

    # @return [void]
    def load_sources
      @generation = @generation.next
      source_hash.clear
      return if directory.empty? || directory == '*'
      size = config.calculated.length
      raise WorkspaceTooLargeError, "The workspace is too large to index (#{size} files, #{config.max_files} max)" if config.max_files.positive? && size > config.max_files
      config.calculated.each do |filename|
        source_hash[filename] = Solargraph::Source.load(filename)
      rescue Errno::ENOENT => e
        Solargraph.logger.warn("Error loading #{filename}: [#{e.class}] #{e.message}")
      end
    end

    # @return [void]
    def require_plugins
      config.plugins.each do |plugin|
        require plugin
      rescue LoadError
        Solargraph.logger.warn "Failed to load plugin '#{plugin}'"
      end
    end

    # @return [String, nil]
    def read_rbs_collection_path
      return unless rbs_collection_config_path

      path = YAML.load_file(rbs_collection_config_path)&.fetch('path')
      # make fully qualified
      File.expand_path(path, directory)
    end
  end
end
