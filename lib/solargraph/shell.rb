# frozen_string_literal: true

require 'benchmark'
require 'thor'
require 'yard'
require 'yaml'
require 'pathname'
require 'sord'
require 'tmpdir'

module Solargraph
  class Shell < Thor
    include Solargraph::ServerMethods
    include ApiMap::SourceToYard

    # Tell Thor to ensure the process exits with status 1 if any error happens.
    def self.exit_on_failure?
      true
    end

    map %w[--version -v] => :version

    desc '--version, -v', 'Print the version'
    # @return [void]
    def version
      puts Solargraph::VERSION
    end

    desc 'socket', 'Run a Solargraph socket server'
    option :host, type: :string, aliases: :h, desc: 'The server host', default: '127.0.0.1'
    option :port, type: :numeric, aliases: :p, desc: 'The server port', default: 7658
    # @return [void]
    def socket
      require 'backport'
      port = options[:port]
      port = available_port if port.zero?
      Backport.run do
        Signal.trap('INT') do
          Backport.stop
        end
        Signal.trap('TERM') do
          Backport.stop
        end
        # @sg-ignore Wrong argument type for Backport.prepare_tcp_server: adapter expected Backport::Adapter, received Module<Solargraph::LanguageServer::Transport::Adapter>
        Backport.prepare_tcp_server host: options[:host], port: port, adapter: Solargraph::LanguageServer::Transport::Adapter
        $stderr.puts "Solargraph is listening PORT=#{port} PID=#{Process.pid}"
      end
    end

    desc 'stdio', 'Run a Solargraph stdio server'
    # @return [void]
    def stdio
      require 'backport'
      Backport.run do
        Signal.trap('INT') do
          Backport.stop
        end
        Signal.trap('TERM') do
          Backport.stop
        end
        # @sg-ignore Wrong argument type for Backport.prepare_stdio_server: adapter expected Backport::Adapter, received Module<Solargraph::LanguageServer::Transport::Adapter>
        Backport.prepare_stdio_server adapter: Solargraph::LanguageServer::Transport::Adapter
        $stderr.puts "Solargraph is listening on stdio PID=#{Process.pid}"
      end
    end

    desc 'config [DIRECTORY]', 'Create or overwrite a default configuration file'
    option :extensions, type: :boolean, aliases: :e, desc: 'Add installed extensions', default: true
    # @param directory [String]
    # @return [void]
    def config directory = '.'
      matches = []
      if options[:extensions]
        Gem::Specification.each do |g|
          if g.name.match(/^solargraph-[A-Za-z0-9_-]*?-ext/)
            require g.name
            matches.push g.name
          end
        end
      end
      conf = Solargraph::Workspace::Config.new.raw_data
      unless matches.empty?
        matches.each do |m|
          conf['extensions'].push m
        end
      end
      # @param file [File]
      File.open(File.join(directory, '.solargraph.yml'), 'w') do |file|
        file.puts conf.to_yaml
      end
      $stdout.puts 'Configuration file initialized.'
    end

    desc 'clear', 'Delete all cached documentation'
    long_desc %(
      This command will delete all core and gem documentation from the cache.
    )
    # @return [void]
    def clear
      puts 'Deleting all cached documentation (gems, core and stdlib)'
      Solargraph::CacheDir.clear
    end
    map 'clear-cache' => :clear
    map 'clear-cores' => :clear

    desc 'uncache GEM [...GEM]', 'Delete specific cached gem documentation'
    long_desc %(
      Specify one or more gem names to clear. 'core' or 'stdlib' may
      also be specified to clear cached system documentation.
      Documentation will be regenerated as needed.
    )
    option :directory, type: :string, desc: 'Workspace directory', default: Dir.pwd
    # @param gems [Array<String>]
    # @return [void]
    def uncache *gems
      raise ArgumentError, 'No gems specified.' if gems.empty?
      repo = Solargraph::Repo.new(options[:directory])

      gems.each do |gem|
        if gem == 'core'
          Solargraph::Collection::Core.uncache
        elsif gem == 'stdlib'
          FileUtils.rm_rf CacheDir.stdlib_dir
        else
          metagem = repo.find_by_name(gem)
          Solargraph::Collection::Gem.uncache(metagem) if metagem
        end
      end
    end

    desc 'cache GEM_NAME [...GEM_NAME] [core]', 'Cache documentation for
         installed libraries'
    long_desc %( This command will cache the
    generated type documentation for the specified libraries.  While
    Solargraph will generate this on the fly when needed, it takes
    time.  This command will generate it in advance, which can be
    useful for CI scenarios.

        With no arguments, it will cache all libraries in the current
        workspace.  If a gem or standard library name is specified, it
        will cache that library's type documentation.

        An equals sign after a gem will allow a specific gem version
        to be cached.

        The 'core' argument can be used to cache the type
        documentation for the core Ruby libraries.

        If the library is already cached, it will be rebuilt if the
        --rebuild option is set.

        Cached documentation is stored in #{CacheDir.base_dir}, which
        can be stored between CI runs.
    )
    option :directory, type: :string, desc: 'Workspace directory', default: Dir.pwd
    option :rebuild, type: :boolean, desc: 'Rebuild existing documentation', default: false
    # @param names [Array<String>]
    # @return [void]
    # @param [Array<Object>] gem_names
    def cache *gem_names
      repo = Solargraph::Repo.new(options[:directory])
      metagems = if gem_names.empty?
                   if repo.bundled?
                     repo.bundled.select(&:cacheable?)
                   else
                     Gem::Specification.all_names
                                       .map { |name| Gem::Specification.find_by_full_name(name) }
                                       .map { |gemspec| Metagem.from_specification(gemspec) }
                   end
                 else
                   gem_names.each_with_object([]) do |name, result|
                     if name == 'core'
                       Collection::Core.uncache if options[:rebuild]
                       puts 'Caching core'
                       Collection::Core.load
                     else
                       # @todo Quick and dirty hack for solargraph-rspec require bug
                       #   (see https://github.com/lekemula/solargraph-rspec/pull/38)
                       #   TL;DR: `repo.find_by_path` should not be necessary
                       found = repo.find_by_name(name) || repo.find_by_path(name)
                       if found
                         result.push found
                       else
                         warn "Gem #{name} not found"
                       end
                     end
                   end
                 end
      metagems.each do |metagem|
        Collection::Gem.uncache(metagem) if options[:rebuild]
        puts "Caching #{metagem.name} #{metagem.version} (#{metagem.cache_name})"
        Collection::Gem.load(metagem)
      end
      puts "Documentation cached for #{metagems.count} gems."
    end
    map 'gems' => :cache

    desc 'bundle', 'Cache all bundled gems'
    option :directory, type: :string, desc: 'Workspace directory', default: Dir.pwd
    def bundle
      repo = Solargraph::Repo.new(options[:directory])
      raise "Bundle not found in #{options[:directory]}" unless repo.bundled?

      repo.bundled.each do |metagem|
        next if Collection::Gem.cached?(metagem)

        puts "Caching #{metagem.name} #{metagem.version}"
        Collection::Gem.load(metagem)
      end
    end

    desc 'reporters', 'Get a list of diagnostics reporters'
    # @return [void]
    def reporters
      puts Solargraph::Diagnostics.reporters
    end

    desc 'typecheck [FILE(s)]', 'Run the type checker'
    long_desc %(
      Perform type checking on one or more files in a workspace. Check the
      entire workspace if no files are specified.

      Type checking levels are normal, typed, strict, and strong.
    )
    option :level, type: :string, aliases: %i[mode m l], desc: 'Type checking level', default: 'normal'
    option :directory, type: :string, aliases: :d, desc: 'The workspace directory', default: '.'
    # @return [void]
    def typecheck *files
      directory = File.realpath(options[:directory])
      workspace = Solargraph::Workspace.new(directory)
      level = options[:level].to_sym
      rules = workspace.rules(level)
      api_map =
        Solargraph::ApiMap.load_with_cache(directory, $stdout,
                                           loose_unions:
                                             !rules.require_all_unique_types_support_call?)
      probcount = 0
      if files.empty?
        files = api_map.source_maps.map(&:filename)
      else
        files.map! { |file| File.realpath(file) }
      end
      filecount = 0
      time = Benchmark.measure do
        files.each do |file|
          checker = TypeChecker.new(file, api_map: api_map, rules: rules, level: options[:level].to_sym,
                                          workspace: workspace)
          problems = checker.problems
          next if problems.empty?
          problems.sort! { |a, b| a.location.range.start.line <=> b.location.range.start.line }
          puts problems.map { |prob|
            "#{prob.location.filename}:#{prob.location.range.start.line + 1}: #{prob.message}"
          }.join("\n")
          filecount += 1
          probcount += problems.length
        end
      end
      puts "Typecheck finished in #{time.real} seconds."
      puts "#{probcount} problem#{if probcount != 1
                                    's'
                                  end} found#{if files.length != 1
                                                                  " in #{filecount} of #{files.length} files"
                                                                end}."
      # "
      exit 1 if probcount.positive?
    end

    desc 'scan', 'Test the workspace for problems'
    long_desc %(
      A scan loads the entire workspace to make sure that the ASTs and
      maps do not raise errors during analysis. It does not perform any type
      checking or validation; it only confirms that the analysis itself is
      error-free.
    )
    option :directory, type: :string, aliases: :d, desc: 'The workspace directory', default: '.'
    option :verbose, type: :boolean, aliases: :v, desc: 'Verbose output', default: false
    # @return [void]
    def scan
      directory = File.realpath(options[:directory])
      # @type [Solargraph::ApiMap, nil]
      api_map = nil
      time = Benchmark.measure do
        api_map = Solargraph::ApiMap.load_with_cache(directory, $stdout)
        # @sg-ignore flow sensitive typing should be able to handle redefinition
        api_map.pins.each do |pin|
          puts pin_description(pin) if options[:verbose]
          pin.typify api_map
          pin.probe api_map
        rescue StandardError => e
          # @todo to add nil check here
          # @todo should warn on nil dereference below
          warn "Error testing #{pin_description(pin)} #{if pin.location
                                                          "at #{pin.location.filename}:#{pin.location.range.start.line + 1}"
                                                        end}"
          warn "[#{e.class}]: #{e.message}"
          # @todo Need to add nil check here
          # @todo flow sensitive typing should be able to handle redefinition
          warn e.backtrace.join("\n")
          exit 1
        end
      end
      # @sg-ignore Need to add nil check here
      puts "Scanned #{directory} (#{api_map.pin_count} pins) in #{time.real} seconds."
    end

    desc 'list', 'List the files in the workspace and the total count'
    option :count, type: :boolean, aliases: :c, desc: 'Display the file count only', default: false
    option :directory, type: :string, aliases: :d, desc: 'The directory to read', default: '.'
    # @return [void]
    def list
      workspace = Solargraph::Workspace.new(options[:directory])
      puts workspace.filenames unless options[:count]
      puts "#{workspace.filenames.length} files total."
    end

    desc 'pin [PATH]', 'Describe a pin'
    option :rbs, type: :boolean, desc: 'Output the pin as RBS', default: false
    option :typify, type: :boolean, desc: 'Output the calculated return type of the pin from annotations',
                    default: false
    option :references, type: :boolean, desc: 'Show references', default: false
    option :probe, type: :boolean, desc: 'Output the calculated return type of the pin from annotations and inference',
                   default: false
    option :stack, type: :boolean, desc: 'Show entire stack of a method pin by including definitions in superclasses',
                   default: false
    # @param path [String] The path to the method pin, e.g. 'Class#method' or 'Class.method'
    # @return [void]
    def pin path
      api_map = Solargraph::ApiMap.load_with_cache('.', $stderr)
      is_method = path.include?('#') || path.include?('.')
      if is_method && options[:stack]
        scope, ns, meth = if path.include? '#'
                            [:instance, *path.split('#', 2)]
                          else
                            [:class, *path.split('.', 2)]
                          end

        # @sg-ignore Wrong argument type for
        #   Solargraph::ApiMap#get_method_stack: rooted_tag
        #   expected String, received Array<String>
        pins = api_map.get_method_stack(ns, meth, scope: scope)
      else
        pins = api_map.get_path_pins path
      end
      # @type [Hash{Symbol => Pin::Base}]
      references = {}
      pin = pins.first
      case pin
      when nil
        warn "Pin not found for path '#{path}'"
        exit 1
      when Pin::Namespace
        if options[:references]
          # @sg-ignore Need to add nil check here
          superclass_tag = api_map.qualify_superclass(pin.return_type.tag)
          superclass_pin = api_map.get_path_pins(superclass_tag).first if superclass_tag
          references[:superclass] = superclass_pin if superclass_pin
        end
      end

      pins.each do |pin|
        if options[:typify] || options[:probe]
          type = ComplexType::UNDEFINED
          type = pin.typify(api_map) if options[:typify]
          type = pin.probe(api_map) if options[:probe] && type.undefined?
          print_type(type)
          next
        end

        print_pin(pin)
      end
      references.each do |key, refpin|
        puts "\n# #{key.to_s.capitalize}:\n\n"
        print_pin(refpin)
      end
    end

    desc 'profile [FILE]', 'Profile workspace mapping, the first catalog and go-to-definition using vernier'
    option :directory, type: :string, aliases: :d, desc: 'The workspace directory', default: '.'
    option :output_dir, type: :string, aliases: :o, desc: 'The output directory for profiles', default: './tmp/profiles'
    option :line, type: :numeric, aliases: :l, desc: 'Line number, 0-based (editor line 1 is 0)', default: 4
    option :column, type: :numeric, aliases: :c, desc: 'Column number, 0-based', default: 10
    option :runs, type: :numeric, aliases: :r, desc: 'Go-to-definition requests to run (the first one, then warm)',
                  default: 3
    option :memory, type: :boolean, aliases: :m, desc: 'Include memory usage counter', default: true
    # @param file [String, nil]
    # @return [void]
    def profile file = nil
      begin
        require 'vernier'
      rescue LoadError
        $stderr.puts 'vernier gem not found. Please install this dependency:'
        $stderr.puts
        $stderr.puts "  gem 'vernier', '>1.0', '<2'"

        return
      end

      hooks = []
      hooks << :memory_usage if options[:memory]

      directory = File.realpath(options[:directory])
      test_file = profile_test_file(directory, file)
      return puts('No Ruby files found in workspace') if test_file.nil?

      FileUtils.mkdir_p(options[:output_dir])

      host = Solargraph::LanguageServer::Host.new
      host.client_capabilities.merge!({ 'window' => { 'workDoneProgress' => true } })
      # @param method [String] The message method
      # @param params [Hash] The method parameters
      # @return [void]
      def host.send_notification method, params
        puts "Notification: #{method} - #{params}"
      end
      phases = Solargraph::ProfilePhases.new(host)

      parse_path = File.join(options[:output_dir], 'parse_benchmark.json.gz')
      catalog_path = File.join(options[:output_dir], 'catalog_benchmark.json.gz')
      definition_path = File.join(options[:output_dir], 'definition_benchmark.json.gz')

      # @type [Hash{String => Float}]
      times = {}
      # @type [Array<Float>]
      definition_times = []

      # Trap CTRL-C so the in-progress Vernier.profile block can unwind through
      # its ensure clause and still write its output file. A second CTRL-C
      # restores default handling for a hard exit.
      interrupted = false
      previous_int_trap = Signal.trap('INT') do
        if interrupted
          Signal.trap('INT', 'DEFAULT')
          Process.kill('INT', Process.pid)
        else
          interrupted = true
          puts "\nInterrupted. Finishing current profile (CTRL-C again to force exit)..."
          raise Interrupt
        end
      end

      begin
        puts 'Parsing and mapping source files...'
        times['Parsing & mapping'] = profile_phase(parse_path, hooks) { phases.map(directory) }

        puts 'Building the catalog...'
        times['Catalog building'] = profile_phase(catalog_path, hooks) { phases.catalog }

        file_uri = Solargraph::LanguageServer::UriHelpers.file_to_uri(test_file)
        puts "Profiling go-to-definition for #{test_file}"
        puts "Position: line #{options[:line]}, column #{options[:column]} (0-based)"
        print_profile_position(test_file, options[:line], options[:column])

        times['Go-to-definition'] = profile_phase(definition_path, hooks) do
          options[:runs].times do
            result = nil
            time = measure { result = phases.definition(file_uri, options[:line], options[:column]) }
            definition_times.push(time)
            puts "Run #{definition_times.length}: #{format_ms(time)} - #{result.inspect}"
          end
        end
      rescue Interrupt
        puts "\nProfile run interrupted; partial profile(s) have been written."
      ensure
        Signal.trap('INT', previous_int_trap || 'DEFAULT')

        puts "\n=== Timing Results ==="
        times.each { |name, time| puts "#{name}: #{format_ms(time)}" }
        definition_times.each_with_index do |time, index|
          puts "  #{index.zero? ? 'first' : 'warm'} request: #{format_ms(time)}"
        end
        puts "Total time: #{format_ms(times.values.sum(0.0))}" if times.length == 3

        saved = [parse_path, catalog_path, definition_path].select { |p| File.exist?(p) }
        unless saved.empty?
          puts "\nProfiles saved to:"
          saved.each { |p| puts "  - #{File.expand_path(p)}" }

          puts "\nUpload the JSON files to https://vernier.prof/ to view the profiles."
          puts 'Or use https://rubygems.org/gems/profile-viewer to view them locally.'
        end
      end
    end

    desc 'rbs', 'Generate RBS definitions'
    option :filename, type: :string, alias: :f, desc: 'Generated file name', default: 'sig.rbs'
    option :inference, type: :boolean, desc: 'Enhance definitions with type inference', default: true
    def rbs
      api_map = Solargraph::ApiMap.load('.')
      pins = api_map.source_maps.flat_map(&:pins)
      store = Solargraph::ApiMap::Store.new(pins)
      if options[:inference]
        puts 'Inferring untyped methods...'
        store.method_pins.each do |pin|
          next unless pin.return_type.undefined?
          type = pin.typify(api_map)
          type = pin.probe(api_map) if type.undefined?
          pin.docstring.add_tag YARD::Tags::Tag.new('return', nil, type.items.map(&:to_s))
          pin.instance_variable_set(:@return_type, type)
        end
      end
      puts 'Generating yardocs...'
      rake_yard(store)
      work_dir = Dir.pwd
      Dir.mktmpdir do |tmpdir|
        Dir.chdir tmpdir do
          yardoc = File.join(tmpdir, '.yardoc')
          YARD::Registry.save(false, yardoc)
          YARD::Registry.load(yardoc)
          rel_dir = File.join('sig', options[:filename])
          puts "Writing #{rel_dir}..."
          target = File.join(work_dir, rel_dir)
          FileUtils.mkdir_p(File.join(work_dir, 'sig'))
          `sord #{target} --rbs --no-regenerate`
        end
      end
      puts 'Done.'
    end

    private

    # @param directory [String]
    # @param file [String, nil]
    # @return [String, nil]
    def profile_test_file directory, file
      return File.join(directory, file) if file

      default = File.join(directory, 'lib', 'other.rb')
      return default if File.exist?(default)

      Solargraph::Workspace.new(directory).filenames.find { |f| f.end_with?('.rb') }
    end

    # @param path [String]
    # @param hooks [Array<Symbol>]
    # @return [Float] wall time in seconds, without writing the profile
    def profile_phase path, hooks, &block
      time = 0.0
      # @sg-ignore vernier is an optional dependency loaded by #profile
      Vernier.profile(out: path, hooks: hooks) { time = measure(&block) }
      time
    end

    # @return [Float] wall time in seconds
    def measure
      start = Time.now
      yield
      Time.now - start
    end

    # @param seconds [Float]
    # @return [String]
    def format_ms seconds
      "#{(seconds * 1000).round(2)}ms"
    end

    # @param filename [String]
    # @param line [Integer] 0-based
    # @param column [Integer] 0-based
    # @return [void]
    def print_profile_position filename, line, column
      text = File.readlines(filename)[line]
      return puts("Line #{line} is past the end of #{filename}") if text.nil?

      puts "  #{text.chomp}"
      puts "  #{' ' * column}^"
    end

    # @param pin [Solargraph::Pin::Base]
    # @return [String]
    def pin_description pin
      desc = if pin.path.nil? || pin.path.empty?
               if pin.closure
                 # @sg-ignore Need to add nil check here
                 "#{pin.closure.path} | #{pin.name}"
               else
                 "#{pin.context.namespace} | #{pin.name}"
               end
             else
               pin.path
             end
      # @sg-ignore Need to add nil check here
      desc += " (#{pin.location.filename} #{pin.location.range.start.line})" if pin.location
      desc
    end

    # @param type [ComplexType, ComplexType::UniqueType]
    # @return [void]
    def print_type type
      if options[:rbs]
        puts type.to_rbs
      else
        puts type.rooted_tag
      end
    end

    # @param pin [Solargraph::Pin::Base]
    # @return [void]
    def print_pin pin
      if options[:rbs]
        puts pin.to_rbs
      else
        puts pin.inspect
      end
    end
  end
end
