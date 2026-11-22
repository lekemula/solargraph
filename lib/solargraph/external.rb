# frozen_string_literal: true

require 'set'

module Solargraph
  # @todo This class might need a way to track changes to the repo, e.g.,
  #   bundle or dependency updates
  #
  class External
    # What the lazy index needs to know about a gem, without keeping its pins.
    class LazySummary
      # @return [Hash{String => Integer}] the namespaces the gem defines, with
      #   how many method and constant pins each holds
      attr_reader :namespaces

      # @return [Array<String>]
      attr_reader :constants

      # @param pins [Array<Pin::Base>]
      def initialize pins
        defined = pins.grep(Pin::Namespace).to_set(&:path)
        # @type [Hash{String, nil => Integer}]
        counts = Hash.new(0)
        pins.each { |pin| counts[pin.namespace] += 1 if External.owning_pin?(pin) }
        @namespaces = defined.to_h { |path| [path, counts[path]] }
        @constants = pins.grep(Pin::Constant).map(&:path)
      end
    end

    class << self
      # Kept per cache file for the process, so a new update does not reload
      # every skipped gem.
      #
      # @param metagem [Metagem]
      # @return [LazySummary]
      def lazy_summary metagem
        key = Collection::Gem.new(metagem).cache_file
        lazy_summaries[key] ||= LazySummary.new(Collection::Gem.load(metagem))
      end

      # @return [Hash{String => LazySummary}]
      def lazy_summaries
        @lazy_summaries ||= {}
      end

      # @param pin [Pin::Base]
      # @return [Boolean]
      def owning_pin? pin
        pin.is_a?(Pin::Method) || pin.is_a?(Pin::Constant)
      end
    end

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
    # @param included_gems [Array<String>] Names of gems to map in every mode
    # @param excluded_gems [Array<String>] Names of gems never to map, however
    #   they are reached
    # @param lazy_load [Integer] How many skipped gems may load on first
    #   reference and stay loaded, least recently used first out
    def initialize directory, requires, extra_gem_names = [], direct_only: false, included_gems: [],
                   excluded_gems: [], lazy_load: 0
      @repo = Repo.new(directory)
      @directory = directory
      @requires = requires
      @extra_gem_names = extra_gem_names
      @direct_only = direct_only
      @included_gem_names = included_gems
      @excluded_gem_names = excluded_gems.to_set
      @lazy_limit = lazy_load
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

    # Gems left out because the configuration excludes them.
    #
    # @return [Set<Metagem>]
    def excluded_gems
      @excluded_gems ||= Set.new
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

    # The pins of skipped gems that loaded on first reference.
    #
    # @return [Array<Pin::Base>]
    def lazy_pins
      @lazy_pins ||= []
    end

    # @return [Integer] incremented whenever lazy_pins changes
    def lazy_generation
      @lazy_generation ||= 0
    end

    # Names of the skipped gems that loaded on first reference, least
    # recently used first.
    #
    # @return [Array<String>]
    def lazy_gem_names
      lazy_ticks.sort_by(&:last).map(&:first)
    end

    # Load the skipped gem that owns a namespace or constant path, or mark it
    # as recently used if it is loaded already.
    #
    # @param path [String] A namespace, constant or method path
    # @return [Boolean] True if lazy_pins changed
    def lazy_load path
      return false if lazy_index.empty?

      metagem = lazy_gem_for(path)
      return false unless metagem

      @lazy_tick = (@lazy_tick || 0) + 1
      lazy_ticks[metagem.name] = @lazy_tick
      return false if lazy_gems.key?(metagem.name)

      lazy_gems[metagem.name] = [metagem, gem_pins(metagem)]
      evict_lazy_gems
      @lazy_pins = lazy_gems.values.flat_map(&:last)
      @lazy_generation = lazy_generation + 1
      Solargraph.logger.info "Loaded skipped gem #{metagem.name} on first reference to #{path}"
      true
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
      load_included_gems
      # load_rbs_collection
      build_lazy_index
      release_unused_gem_caches if direct_only? || @excluded_gem_names.any?
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

    # @return [void]
    def load_included_gems
      @included_gem_names.uniq.each do |gem|
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
      used_gems = loaded_gems.to_a + lazy_gems.values.map(&:first)
      used = used_gems.select(&:cacheable?).to_set { |metagem| Collection::Gem.new(metagem).cache_file }
      gem_dir = "#{CacheDir.gem_dir}#{File::SEPARATOR}"
      Collection.mem_cache.delete_if do |key, _|
        key.start_with?(gem_dir) && !used.include?(key.split('|').first)
      end
    end

    # @return [Hash{String => Array(Metagem, Array<Pin::Base>)}] by gem name
    def lazy_gems
      @lazy_gems ||= {}
    end

    # @return [Hash{String => Integer}] when each lazily loaded gem was last
    #   referred to
    def lazy_ticks
      @lazy_ticks ||= {}
    end

    # @return [Hash{String => Metagem}] the skipped gem that owns each path
    def lazy_index
      @lazy_index ||= {}
    end

    # @param path [String]
    # @return [Metagem, nil]
    def lazy_gem_for path
      key = path.delete_prefix('::').split(/[#.]/, 2).first
      return if key.nil?

      lazy_index[key] || lazy_index[key.split('::', 2).first]
    end

    # Index the namespaces and constants that a skipped gem owns: a namespace
    # that only skipped gems define, or whose methods and constants come mostly
    # from that gem rather than from the mapped pins. Gems that only add
    # methods to a namespace of another gem or of the core do not load on its
    # lookups.
    #
    # @return [void]
    def build_lazy_index
      @lazy_index = {}
      @lazy_gems = {}
      @lazy_ticks = {}
      @lazy_pins = []
      @lazy_generation = lazy_generation + 1
      candidates = lazy_candidates.select { |metagem| Collection::Gem.cached?(metagem) }
      return if @lazy_limit <= 0 || candidates.empty?

      # @type [Array<Pin::Base>]
      mapped = Collection::Core.load + pins
      # @type [Hash{String, nil => Integer}]
      resident = Hash.new(0)
      mapped.each { |pin| resident[pin.namespace] += 1 if External.owning_pin?(pin) }
      resident_paths = mapped.select { |pin| pin.is_a?(Pin::Namespace) || pin.is_a?(Pin::Constant) }.to_set(&:path)
      best = {}
      candidates.each do |metagem|
        External.lazy_summary(metagem).namespaces.each do |path, count|
          next if resident_paths.include?(path) && resident.fetch(path, 0) >= count
          next if best[path] && best[path][1] >= count

          best[path] = [metagem, count]
        end
      end
      best.each { |path, (metagem, _)| @lazy_index[path] = metagem }
      candidates.each do |metagem|
        External.lazy_summary(metagem).constants.each do |path|
          @lazy_index[path] ||= metagem unless resident_paths.include?(path)
        end
      end
    end

    # The skipped gems and the dependencies they bring, which were never
    # visited because their parent was skipped. Excluded gems are left out.
    #
    # @return [Array<Metagem>]
    def lazy_candidates
      seen = (loaded_gems.to_a + unloaded_gems.to_a + excluded_gems.to_a).to_set(&:name)
      # @type [Array<Metagem>]
      result = []
      # @type [Array<Metagem>]
      queue = skipped_gems.to_a
      # each also visits the dependencies pushed while it runs
      queue.each do |metagem|
        next if seen.include?(metagem.name) || @excluded_gem_names.include?(metagem.name)

        seen.add metagem.name
        result.push metagem
        metagem.dependencies.each do |name|
          dependency = @repo.find_by_name(name)
          queue.push dependency if dependency
        end
      end
      result
    end

    # @return [void]
    def evict_lazy_gems
      while lazy_gems.size > @lazy_limit
        name = lazy_ticks.min_by(&:last)&.first
        break unless name

        lazy_ticks.delete(name)
        metagem = lazy_gems.delete(name)&.first
        next unless metagem

        cache_file = Collection::Gem.new(metagem).cache_file
        Collection.mem_cache.delete_if { |key, _| key == cache_file || key.start_with?("#{cache_file}|") }
        Solargraph.logger.info "Evicted skipped gem #{name}"
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
      excluded_gems.clear
    end

    # @param metagem [Metagem]
    # @param required [Boolean] True if a require or an extra gem name asks
    #   for the gem itself, as opposed to reaching it as a dependency
    # @return [void]
    def process_gem metagem, required: false
      return if loaded_gems.include?(metagem) || unloaded_gems.include?(metagem)
      return excluded_gems.add(metagem) if @excluded_gem_names.include?(metagem.name)
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
