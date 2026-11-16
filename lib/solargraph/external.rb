# frozen_string_literal: true

require 'set'

module Solargraph
  # @todo This class might need a way to track changes to the repo, e.g.,
  #   bundle or dependency updates
  #
  class External
    # @return [String]
    attr_reader :directory

    # @return [Array<String>]
    attr_reader :requires

    attr_reader :extra_gem_names

    # @param directory [String, nil]
    # @param requires [Array<String>]
    # @param extra_gem_names [Array<String>]
    # @param direct_only [Boolean] Map only the gems the Gemfile declares
    #   directly, plus the gems that requires and extra gem names resolve to
    def initialize directory, requires, extra_gem_names = [], direct_only: false
      @repo = Repo.new(directory)
      @directory = directory
      @requires = requires
      @extra_gem_names = extra_gem_names
      @direct_only = direct_only
      update!
    end

    def configured_gem_names
      loaded_gems.map(&:name) + unloaded_gems.map(&:name) + extra_gem_names
    end

    def unresolved_requires
      @unresolved_requires ||= []
    end

    def unresolved_dependencies
      @unresolved_dependencies ||= []
    end

    def loaded_gems
      @loaded_gems ||= Set.new
    end

    def unloaded_gems
      @unloaded_gems ||= Set.new
    end

    def direct_only?
      @direct_only
    end

    # Transitive dependencies left out because only direct gems are mapped.
    #
    # @return [Set<Metagem>]
    def skipped_gems
      @skipped_gems ||= Set.new
    end

    def unfound_gem_names
      @unfound_gem_names ||= []
    end

    def loaded_stdlibs
      @loaded_stdlibs ||= Set.new
    end

    def pins
      @pins ||= []
    end

    # @return [Integer] incremented whenever the external pin set is rebuilt
    def generation
      @generation ||= 0
    end

    # @param new_requires [Array<String>]
    # @return [Boolean]
    def update new_requires, new_gem_names = []
      return false if requires == new_requires && new_gem_names == extra_gem_names && !cache_changed?

      requires.replace new_requires
      extra_gem_names.replace new_gem_names
      update!
      true
    end

    private

    def update!
      @generation = generation + 1
      clear_all
      load_requires
      load_gem_names
      # load_rbs_collection
      release_unused_gem_caches if direct_only?
      return if skipped_gems.empty?

      Solargraph.logger.info "Skipped #{skipped_gems.size} transitive gems that nothing requires"
    end

    def cache_changed?
      unloaded_gems.any? { |gem| Collection::Gem.cached?(gem) }
    end

    def load_requires
      bundler_require = false

      requires.uniq.each do |path|
        if path == 'bundler/require'
          bundler_require = true
        end
        if RbsMap::Stdlib.has?(path)
          pins.concat Collection::Stdlib.load(path) if loaded_stdlibs.add?(path)
        else
          metagem = @repo.find_by_path(path)
          next unresolved_requires.push(path) unless metagem
          process_gem metagem, required: true
        end
      end

      return unless bundler_require

      @repo.find_by_group(:default).each { |metagem| process_gem metagem }
    end

    def load_gem_names
      extra_gem_names.uniq.each do |gem|
        metagem = @repo.find_by_name(gem)
        next unfound_gem_names.push(gem) unless metagem
        process_gem metagem, required: true
      end
    end

    # Other ApiMaps in the process, such as the catalogs that map path gems,
    # can load gems this External leaves out. Their pins would stay in the
    # process-wide memo although nothing uses them.
    #
    # @return [void]
    def release_unused_gem_caches
      used = loaded_gems.select(&:cacheable?).to_set { |metagem| Collection::Gem.new(metagem).cache_file }
      gem_dir = "#{CacheDir.gem_dir}#{File::SEPARATOR}"
      Collection.mem_cache.delete_if do |key, _|
        key.start_with?(gem_dir) && !used.include?(key.split('|').first)
      end
    end

    def rbs_collection
      @rbs_collection ||= RbsCollection.new(rbs_collection_lockfile)
    end

    def rbs_collection_lockfile
      return if directory.nil? || directory.empty? || directory == '*'
      lockfile = File.join(directory, 'rbs_collection.lock.yaml')
      lockfile if File.file?(lockfile)
    end

    def clear_all
      pins.clear
      unresolved_requires.clear
      unresolved_dependencies.clear
      loaded_gems.clear
      unloaded_gems.clear
      loaded_stdlibs.clear
      unfound_gem_names.clear
      skipped_gems.clear
    end

    # @param metagem [Metagem]
    # @param required [Boolean] True if a require or an extra gem name asks
    #   for the gem itself, as opposed to reaching it as a dependency
    # @return [void]
    def process_gem metagem, required: false
      return if loaded_gems.include?(metagem) || unloaded_gems.include?(metagem)
      return skipped_gems.add(metagem) if skip?(metagem, required)

      skipped_gems.delete(metagem)
      if metagem.cacheable? && !Collection::Gem.cached?(metagem)
        unloaded_gems.add metagem
      else
        loaded_gems.add metagem
        loaded_pins = gem_pins(metagem)
        pins.concat loaded_pins
        # Gems might not declare stdlib dependencies as gem dependencies
        # (e.g., `activesupport` requires `date`)
        loaded_pins.select { |pin| pin.is_a?(Pin::Reference::Require) && RbsMap::Stdlib.has?(pin.name) }
                   .each do |pin|
                     pins.concat Collection::Stdlib.load(pin.name) if loaded_stdlibs.add?(pin.name)
                   end
      end
      load_dependencies metagem
    end

    # A gem's pins, combined with its signatures in the RBS collection.
    #
    # @param metagem [Metagem]
    # @return [Array<Pin::Base>]
    def gem_pins metagem
      signatures = rbs_collection.signature_path(metagem)
      return Collection::Gem.load(metagem) unless signatures
      Collection::Gem.combine(metagem, signatures) { rbs_collection.load(metagem) }
    end

    # @param metagem [Metagem]
    # @param required [Boolean]
    def skip? metagem, required
      return false if required || !@direct_only

      direct = @repo.direct_gem_names
      !direct.nil? && !direct.include?(metagem.name)
    end

    def load_dependencies parent
      parent.dependencies.each do |name|
        next if loaded_gems.map(&:name).include?(name) || unloaded_gems.map(&:name).include?(name)
        metagem = @repo.find_by_name(name)
        next unresolved_dependencies.push(name) unless metagem
        process_gem metagem
      end
    end
  end
end
