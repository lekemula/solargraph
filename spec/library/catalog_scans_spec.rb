# frozen_string_literal: true

require 'objspace'
require 'tmpdir'

describe Solargraph::ApiMap, '#catalog with evicted sources' do
  let(:dir) { File.realpath(Dir.mktmpdir) }
  let(:widget) { File.join(dir, 'widget.rb') }
  let(:settings) { File.join(dir, 'settings.rb') }
  let(:plain) { File.join(dir, 'plain.rb') }
  let(:script) { File.join(dir, 'script.rb') }

  before do
    Solargraph::SourceCache.reset!
    # rubocop:disable-next RSpec/AnyInstance
    allow_any_instance_of(Solargraph::External).to receive(:configured_gem_names).and_return(['activesupport'])
    File.write(File.join(dir, 'base.rb'), <<~RUBY)
      class Base
        # @!macro make_method
        #   @!method $1
        #     @return [String]
        def self.make_method name
        end
      end
    RUBY
    File.write(widget, <<~RUBY)
      class Widget < Base
        # Spins the widget
        make_method :spin
      end
    RUBY
    File.write(settings, <<~RUBY)
      class Settings
        # The level
        mattr_accessor :level
      end
    RUBY
    File.write(plain, <<~RUBY)
      class Plain
        def go
          helper
          Widget.make_method :ignored
        end
      end
    RUBY
    File.write(script, "Widget.new.spin\n")
  end

  after do
    Solargraph::SourceCache.reset!
    FileUtils.remove_entry dir
  end

  # @param evict [Boolean]
  # @return [Solargraph::Library]
  def mapped_library evict:
    library = Solargraph::Library.new(Solargraph::Workspace.new(dir), nil, evict_sources: evict)
    library.open_file script
    nil while library.next_map
    library
  end

  # @param library [Solargraph::Library]
  # @return [Solargraph::ApiMap]
  def catalog library
    described_class.new.catalog(library.bench)
  end

  # @param api_map [Solargraph::ApiMap]
  # @return [Array<Array(String, String, String)>]
  def generated api_map
    %w[Widget#spin Settings.level Settings.level= Settings#level Settings#level=].flat_map do |path|
      api_map.get_path_pins(path).map { |pin| [pin.path, pin.location.inspect, pin.comments] }
    end
  end

  # @return [Array<String>] the evicted files parsed from disk during the block
  def parsed_files
    files = []
    allow(Solargraph::SourceCache.instance).to receive(:load).and_wrap_original do |original, filename, stamp|
      files.push filename
      original.call(filename, stamp)
    end
    yield
    files
  end

  it 'generates the same pins as without eviction' do
    expected = generated(catalog(mapped_library(evict: false)))
    expect(expected.map(&:first)).to include('Widget#spin', 'Settings.level', 'Settings#level=')
    expect(generated(catalog(mapped_library(evict: true)))).to eq(expected)
  end

  it 'parses only the files with candidate calls' do
    library = mapped_library(evict: true)
    expect(parsed_files { catalog(library) }).to contain_exactly(widget, settings)
  end

  it 'does not fill the source cache' do
    library = mapped_library(evict: true)
    catalog(library)
    expect(Solargraph::SourceCache.instance.cached_filenames).to be_empty
  end

  it 'uses a cached source instead of parsing it again' do
    library = mapped_library(evict: true)
    Solargraph::SourceCache.instance.fetch(widget)
    expect(parsed_files { catalog(library) }).to eq([settings])
  end

  it 'skips a file that changed on disk' do
    library = mapped_library(evict: true)
    File.write(widget, "# changed\n#{File.read(widget)}")
    expect(generated(catalog(library)).map(&:first)).not_to include('Widget#spin')
    expect(Solargraph::SourceCache.instance.take_stale { true }).to eq([widget])
  end

  it 'keeps the call names of an evicted file' do
    library = mapped_library(evict: true)
    map = library.source_map_hash[plain]
    expect(map).to be_evicted
    expect(map.call_names).to eq(['helper'])
  end

  it 'keeps no syntax tree of a scanned file' do
    api_map = catalog(mapped_library(evict: true))
    expect(generated(api_map).map(&:first)).to include('Widget#spin', 'Settings.level')
    expect(reachable_buffer_texts(api_map) & Set[File.read(widget), File.read(settings)]).to be_empty
  end

  # Texts of the Parser source buffers reachable from an object, not following
  # references through classes and modules.
  #
  # @param root [Object]
  # @return [Set<String>]
  def reachable_buffer_texts root
    seen = {}.compare_by_identity
    sources = Set.new
    queue = [root]
    until queue.empty?
      obj = queue.pop
      next if seen.key?(obj) || obj.is_a?(Module)
      seen[obj] = true
      sources.add obj.source if obj.is_a?(Parser::Source::Buffer)
      ObjectSpace.reachable_objects_from(obj)&.each do |child|
        queue.push child unless child.is_a?(ObjectSpace::InternalObjectWrapper)
      end
    end
    sources
  end
end
