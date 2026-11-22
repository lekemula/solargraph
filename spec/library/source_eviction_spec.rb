# frozen_string_literal: true

require 'objspace'
require 'tmpdir'

describe Solargraph::Library, '#next_map' do
  let(:dir) { File.realpath(Dir.mktmpdir) }
  let(:maker) { File.join(dir, 'maker.rb') }
  let(:product) { File.join(dir, 'product.rb') }
  let(:script) { File.join(dir, 'script.rb') }
  let(:library) { described_class.new(Solargraph::Workspace.new(dir), nil, evict_sources: true) }

  before do
    Solargraph::SourceCache.reset!
    File.write(maker, <<~RUBY)
      class Maker
        def make
          Product.new
        end

        def made
          @made = make
        end

        def each_product
          [make].each { |pr| yield pr }
        end
      end
    RUBY
    File.write(product, <<~RUBY)
      class Product
        def label
          'product'
        end
      end
    RUBY
    File.write(script, <<~RUBY)
      maker = Maker.new
      maker.make.label
      maker.made
    RUBY
  end

  after do
    Solargraph::SourceCache.reset!
    FileUtils.remove_entry dir
  end

  # @return [void]
  def map_workspace
    library.open_file script
    nil while library.next_map
    library.catalog
    library.source_maps.each(&:pins)
  end

  # Names of the Parser source buffers reachable from an object, not following
  # references through classes and modules.
  #
  # @param root [Object]
  # @return [Set<String>]
  def reachable_buffer_names root
    seen = {}.compare_by_identity
    names = Set.new
    queue = [root]
    until queue.empty?
      obj = queue.pop
      next if seen.key?(obj) || obj.is_a?(Module)
      seen[obj] = true
      names.add obj.name if obj.is_a?(Parser::Source::Buffer)
      ObjectSpace.reachable_objects_from(obj)&.each do |child|
        queue.push child unless child.is_a?(ObjectSpace::InternalObjectWrapper)
      end
    end
    names
  end

  # @param filename [String]
  # @param line [Integer]
  # @param column [Integer]
  # @return [Array<String>]
  def definition_paths filename, line, column
    library.definitions_at(filename, line, column).map(&:path)
  end

  it 'keeps no parser buffer of a mapped file that is not open' do
    map_workspace
    expect(reachable_buffer_names(library)).to eq(Set[script])
  end

  it 'keeps no parser buffer of a file that is not open after inference' do
    map_workspace
    expect(definition_paths(script, 1, 13)).to eq(['Product#label'])
    expect(reachable_buffer_names(library) & Set[maker, product]).to be_empty
  end

  it 'infers types across evicted files' do
    map_workspace
    expect(definition_paths(script, 1, 13)).to eq(['Product#label'])
    pin = library.send(:api_map).get_path_pins('Maker#made').first
    expect(pin.probe(library.send(:api_map)).to_s).to eq('Product')
  end

  it 'reloads a node of an evicted file' do
    map_workspace
    pin = library.source_map_hash[maker].pins.find { |p| p.path == 'Maker#make' }
    expect(pin.node.type).to eq(:def)
    block = library.source_map_hash[maker].pins.find { |p| p.is_a?(Solargraph::Pin::Block) }
    expect(block.receiver.type).to eq(:send)
  end

  it 'keeps open files resident' do
    map_workspace
    expect(library.source_map_hash[script]).not_to be_evicted
    expect(library.source_map_hash[script].source).to be(library.workspace.source(script))
    expect(library.source_map_hash[maker]).to be_evicted
  end

  it 'does not evict without the language server' do
    library = described_class.new(Solargraph::Workspace.new(dir))
    nil while library.next_map
    library.source_maps.each(&:pins)
    expect(reachable_buffer_names(library)).to include(maker, product)
  end

  it 'remaps a file that changed on disk instead of inferring from it' do
    map_workspace
    expect(definition_paths(script, 1, 13)).to eq(['Product#label'])
    File.write(maker, "# changed\n#{File.read(maker)}")
    Solargraph::SourceCache.instance.send(:instance_variable_get, :@lru).clear
    library.catalog
    expect(definition_paths(script, 1, 13)).to be_empty
    expect(definition_paths(script, 1, 13)).to eq(['Product#label'])
    expect(library.source_map_hash[maker].pins.find { |p| p.path == 'Maker#make' }.node.loc.last_line).to eq(4)
  end

  it 'evicts a file again when it gets closed' do
    map_workspace
    library.open_file maker
    library.merge Solargraph::Source.load(maker)
    expect(library.source_map_hash[maker].source).to be(library.workspace.source(maker))
    library.close maker
    expect(reachable_buffer_names(library)).to eq(Set[script])
    expect(definition_paths(script, 1, 13)).to eq(['Product#label'])
  end

  it 'reads the cache size from the workspace configuration' do
    File.write(File.join(dir, '.solargraph.yml'), "source_cache_size: 7\n")
    library
    expect(Solargraph::SourceCache.instance.size).to eq(7)
  end
end
