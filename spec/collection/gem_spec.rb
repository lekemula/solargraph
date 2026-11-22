# frozen_string_literal: true

require 'tmpdir'

describe Solargraph::Collection::Gem do
  around do |example|
    Dir.mktmpdir do |dir|
      @gem_dir = File.join(dir, 'node_free-1.0.0')
      FileUtils.mkdir_p File.join(@gem_dir, 'lib')
      File.write File.join(@gem_dir, 'lib', 'node_free.rb'), <<~RUBY
        module Inner
          class Error < StandardError
            class Detail; end
          end
        end

        module NodeFree
          Error = Inner::Error
          LIMIT = 10

          def clock unit = :second
            unit if unit
          end
          module_function :clock

          class Thing
            attr_reader :name

            extend Forwardable

            # @!macro flag
            #   @!method $1
            #     @return [Boolean]
            def self.flag name; end
            flag :ready?

            def_delegators :@items, :size

            def initialize name, opts = {}
              @name = name
              @items = []
              @opts = opts
            end

            def each_item
              @items.each { |item| yield item }
            end

            def wait
              sleep 1 while busy?
              sleep 1 until ready?
            end
          end
        end
      RUBY
      with_env_var('SOLARGRAPH_CACHE', File.join(dir, 'cache')) { example.run }
    end
  end

  let(:metagem) do
    Solargraph::Metagem.new(name: 'node_free', full_path: @gem_dir, spec_file: nil, source: 'rubygems',
                            version: '1.0.0', require_paths: ['lib'], dependencies: [])
  end

  let(:parser_classes) do
    [Parser::AST::Node, Parser::Source::Buffer, Parser::Source::Range, Parser::Source::Map]
  end

  before { Solargraph::Collection.clear_mem_cache }

  # @return [Array<Object>] parser objects reachable from the roots
  def parser_objects_in roots
    seen = {}.compare_by_identity
    found = []
    stack = [roots]
    until stack.empty?
      obj = stack.pop
      next if seen.key?(obj) || obj.is_a?(Module)
      seen[obj] = true
      next found.push(obj) if parser_classes.any? { |klass| obj.is_a?(klass) }
      case obj
      when Array, Set then stack.concat(obj.to_a)
      when Hash then stack.concat(obj.keys + obj.values)
      else obj.instance_variables.each { |ivar| stack.push obj.instance_variable_get(ivar) }
      end
    end
    found
  end

  it 'maps gem source into pins' do
    paths = described_class.new(metagem).pins.map(&:path)
    expect(paths).to include('NodeFree::Error', 'NodeFree::Thing#initialize', 'NodeFree::Thing#size')
  end

  it 'expands macros before detaching nodes' do
    pins = described_class.new(metagem).pins
    expect(pins.find { |pin| pin.path == 'NodeFree::Thing#ready?' }).not_to be_nil
  end

  it 'keeps no parser objects in the pins it returns' do
    expect(parser_objects_in(described_class.new(metagem).pins)).to be_empty
  end

  it 'keeps no parser objects in the cache file' do
    described_class.load(metagem)
    pins = Marshal.load(File.binread(described_class.new(metagem).cache_file)) # rubocop:disable Security/MarshalLoad
    expect(parser_objects_in(pins)).to be_empty
  end

  it 'keeps no parser objects in path gem pins' do
    path_gem = Solargraph::Metagem.new(name: 'node_free', full_path: @gem_dir, spec_file: nil,
                                       source: 'source at node_free', version: '1.0.0',
                                       require_paths: ['lib'], dependencies: [])
    expect(parser_objects_in(described_class.load(path_gem))).to be_empty
  end

  it 'resolves constant aliases from detached pins' do
    api_map = Solargraph::ApiMap.new(pins: described_class.new(metagem).pins)
    expect(api_map.qualify('NodeFree::Error::Detail')).to eq('Inner::Error::Detail')
  end

  it 'treats hash-defaulted parameters of detached pins as keyword splats' do
    method = described_class.new(metagem).pins.find { |pin| pin.path == 'NodeFree::Thing#initialize' }
    expect(method.parameters.map(&:kwrestarg?)).to eq([false, true])
  end

  it 'loads cache files that still hold nodes' do
    pins = Solargraph::SourceMap.load(File.join(@gem_dir, 'lib', 'node_free.rb')).pins
    FileUtils.mkdir_p File.dirname(described_class.new(metagem).cache_file)
    File.binwrite described_class.new(metagem).cache_file, Marshal.dump(pins)
    expect(described_class.load(metagem).map(&:path)).to include('NodeFree::Thing#initialize')
  end
end
