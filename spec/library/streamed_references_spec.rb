# frozen_string_literal: true

require 'tmpdir'

describe Solargraph::Library, '#references_from' do
  let(:dir) { File.realpath(Dir.mktmpdir) }
  let(:library) { described_class.new(Solargraph::Workspace.new(dir), nil, evict_sources: true) }

  before do
    Solargraph::SourceCache.reset!
    File.write(maker, <<~RUBY)
      class Maker
        def make
          Product.new
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
    RUBY
    File.write(commented, <<~RUBY)
      # Prints the label
      class Printer
        def print
          puts 'label'
        end
      end
    RUBY
    File.write(shop, <<~RUBY)
      class Shop
        def show
          Maker.new.make.label
        end
      end
    RUBY
    File.write(absent, <<~RUBY)
      class Absent
        def other; end
      end
    RUBY
  end

  after do
    Solargraph::SourceCache.reset!
    FileUtils.remove_entry dir
  end

  # @return [String]
  def maker
    File.join(dir, 'maker.rb')
  end

  # @return [String]
  def product
    File.join(dir, 'product.rb')
  end

  # @return [String]
  def script
    File.join(dir, 'script.rb')
  end

  # @return [String]
  def commented
    File.join(dir, 'commented.rb')
  end

  # @return [String]
  def absent
    File.join(dir, 'absent.rb')
  end

  # @return [String]
  def shop
    File.join(dir, 'shop.rb')
  end

  # @return [void]
  def map_workspace
    library.open_file script
    library.merge Solargraph::Source.load(script)
    nil while library.next_map
    library.catalog
    library.send(:sync_catalog)
    # The catalog-time scans load every file through the cache.
    Solargraph::SourceCache.instance.size = 0
    Solargraph::SourceCache.instance.size = Solargraph::SourceCache::DEFAULT_SIZE
  end

  # @param locations [Array<Solargraph::Location>]
  # @return [Array(String, Integer, Integer)]
  def summarize locations
    locations.map { |loc| [File.basename(loc.filename), loc.range.start.line, loc.range.start.character] }
  end

  # Files parsed whole while the block runs, one entry per parse. Parses of
  # code fragments, e.g. for chains, are left out.
  #
  # @return [Array<String>]
  def parsed_files
    parsed = []
    allow(Solargraph::Parser).to receive(:parse_with_comments).and_wrap_original do |original, code, filename, *rest|
      parsed.push filename if filename && File.file?(filename) && code == File.read(filename)
      original.call(code, filename, *rest)
    end
    yield
    parsed
  end

  it 'finds the same references as a library that keeps every source' do
    map_workspace
    resident = described_class.new(Solargraph::Workspace.new(dir))
    resident.map!
    resident.catalog
    expect(summarize(library.references_from(script, 1, 12)))
      .to eq(summarize(resident.references_from(script, 1, 12)))
    expect(summarize(library.references_from(script, 1, 12)))
      .to eq([['product.rb', 1, 6], ['script.rb', 1, 11], ['shop.rb', 2, 19]])
  end

  it 'parses only the evicted files whose text mentions the name, once each' do
    map_workspace
    library.definitions_at(script, 1, 13)
    parsed = parsed_files { library.references_from(script, 1, 12) }
    expect(parsed.tally).to eq({ commented => 1, shop => 1 })
  end

  it 'finds nothing in a file that mentions the name only in a comment or string' do
    map_workspace
    expect(library.references_from(script, 1, 12).map(&:filename)).not_to include(commented)
  end

  it 'uses the unsaved text of an open file' do
    map_workspace
    library.open_file product
    library.merge Solargraph::Source.load_string(<<~RUBY, product, 1)
      class Product
        # moved down
        def label
          'product'
        end
      end
    RUBY
    library.catalog
    locations = library.references_from(script, 1, 12)
    expect(summarize(locations)).to eq([['product.rb', 2, 6], ['script.rb', 1, 11], ['shop.rb', 2, 19]])
  end

  it 'leaves the source cache as it was' do
    map_workspace
    library.definitions_at(script, 1, 13)
    before = Solargraph::SourceCache.instance.cached_filenames
    expect(before).not_to be_empty
    library.references_from(script, 1, 12)
    expect(Solargraph::SourceCache.instance.cached_filenames).to eq(before)
  end

  it 'searches only the requested file when asked to' do
    map_workspace
    library.definitions_at(script, 1, 13)
    parsed = parsed_files { library.references_from(script, 1, 12, only: true) }
    expect(parsed).to be_empty
    expect(summarize(library.references_from(script, 1, 12, only: true))).to eq([['script.rb', 1, 11]])
  end
end
