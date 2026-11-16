# frozen_string_literal: true

describe Solargraph::External do
  let(:directory) { File.join('spec', 'fixtures', 'external_bundled_gem') }
  let(:requires) { ['backport', 'gem/with/yard/macros', 'reverse_markdown', 'addressable'] }
  let(:external) { described_class.new(directory, requires) }

  context 'with uncached sources' do
    let(:metagem) { Solargraph::Metagem.from_specification(Gem::Specification.find_by_name('backport')) }

    it 'tracks and updates unloaded gems' do
      Solargraph::Collection::Gem.uncache(metagem)
      expect(external.unloaded_gems.map(&:name)).to include('backport')
      Solargraph::Collection::Gem.load(metagem)
      expect(external.update(requires)).to be(true)
      expect(external.unloaded_gems.map(&:name)).not_to include('backport')
      expect(external.loaded_gems.map(&:name)).to include('backport')
    end
  end

  context 'with cached sources' do
    before(:all) do # rubocop:disable RSpec/BeforeAfterAll
      %w[backport reverse_markdown nokogiri racc].each do |name|
        metagem = Solargraph::Metagem.from_specification(Gem::Specification.find_by_name(name))
        Solargraph::Collection::Gem.load(metagem) unless Solargraph::Collection::Gem.cached?(metagem)
      end
    end

    it 'loads bundled gems' do
      gem_names = external.loaded_gems.map(&:name)
      expect(gem_names).to include('backport')
      expect(gem_names).to include('gem-with-yard-macros')
      expect(gem_names).to include('reverse_markdown')
    end

    it 'loads pins from system sources' do
      paths = external.pins.map(&:path)
      expect(paths).to include('Backport')
      expect(paths).to include('Backport::Server')
      expect(paths).to include('Backport.prepare_stdio_server')
    end

    it 'loads pins from path sources' do
      pins = external.pins.select { |pin| pin.path&.start_with?('Gem::With::Yard::Macros') }
      expect(pins.length).to be_positive
    end

    it 'loads gems from transitive dependencies' do
      # nokogiri is a transitive dependency of reverse_markdown
      expect(external.loaded_gems.map(&:name)).to include('nokogiri')
    end

    context 'with direct gems only' do
      let(:external) { described_class.new(directory, requires, direct_only: true) }

      it 'loads the gems the Gemfile declares' do
        expect(external.loaded_gems.map(&:name)).to include('backport', 'gem-with-yard-macros', 'reverse_markdown')
      end

      it 'skips transitive dependencies' do
        expect(external.loaded_gems.map(&:name)).not_to include('nokogiri')
        expect(external.skipped_gems.map(&:name)).to include('nokogiri')
      end

      it 'keeps no pins of skipped gems' do
        expect(external.pins.map(&:path)).not_to include('Nokogiri')
      end

      it 'loads a required transitive dependency' do
        external = described_class.new(directory, requires + ['nokogiri'], direct_only: true)
        expect(external.loaded_gems.map(&:name)).to include('nokogiri')
        expect(external.skipped_gems.map(&:name)).not_to include('nokogiri')
      end

      it 'loads a transitive dependency named as an extra gem' do
        external = described_class.new(directory, requires, ['nokogiri'], direct_only: true)
        expect(external.loaded_gems.map(&:name)).to include('nokogiri')
      end

      it 'skips transitive dependencies of the default group with bundler/require' do
        external = described_class.new(directory, ['bundler/require'], direct_only: true)
        gem_names = external.loaded_gems.map(&:name)
        expect(gem_names).to include('backport', 'gem-with-yard-macros', 'reverse_markdown')
        expect(gem_names).not_to include('nokogiri')
      end

      it 'loads transitive dependencies without a bundle' do
        external = described_class.new(File.join('spec', 'fixtures', 'external_required_gem'), ['reverse_markdown'],
                                       direct_only: true)
        expect(external.loaded_gems.map(&:name)).to include('nokogiri')
      end

      it 'loads an included transitive dependency' do
        external = described_class.new(directory, requires, direct_only: true, included_gems: ['nokogiri'])
        expect(external.loaded_gems.map(&:name)).to include('nokogiri')
      end
    end

    context 'with excluded gems' do
      it 'skips an excluded transitive dependency' do
        external = described_class.new(directory, requires, excluded_gems: ['nokogiri'])
        expect(external.loaded_gems.map(&:name)).not_to include('nokogiri')
        expect(external.excluded_gems.map(&:name)).to include('nokogiri')
      end

      it 'skips an excluded direct gem with its pins' do
        external = described_class.new(directory, requires, excluded_gems: ['backport'])
        expect(external.loaded_gems.map(&:name)).not_to include('backport')
        expect(external.pins.map(&:path)).not_to include('Backport')
      end

      it 'excludes a gem that a require resolves to' do
        external = described_class.new(directory, requires + ['nokogiri'], excluded_gems: ['nokogiri'])
        expect(external.loaded_gems.map(&:name)).not_to include('nokogiri')
      end

      it 'excludes a gem named as an extra gem' do
        external = described_class.new(directory, requires, ['nokogiri'], excluded_gems: ['nokogiri'])
        expect(external.loaded_gems.map(&:name)).not_to include('nokogiri')
      end

      it 'excludes an included gem' do
        external = described_class.new(directory, requires, direct_only: true, included_gems: ['nokogiri'],
                                                            excluded_gems: ['nokogiri'])
        expect(external.loaded_gems.map(&:name)).not_to include('nokogiri')
      end

      it 'excludes a gem in direct mode' do
        external = described_class.new(directory, requires, direct_only: true, excluded_gems: ['backport'])
        expect(external.loaded_gems.map(&:name)).not_to include('backport')
      end
    end

    context 'with skipped gems loaded on first reference' do
      let(:external) { described_class.new(directory, requires, direct_only: true, lazy_load: 5) }

      it 'loads a skipped gem on a reference to one of its namespaces' do
        expect(external.lazy_load('Nokogiri::HTML::Document')).to be(true)
        expect(external.lazy_gem_names).to eq(['nokogiri'])
        expect(external.lazy_pins.map(&:path)).to include('Nokogiri::HTML::Document')
      end

      it 'loads a gem once' do
        external.lazy_load('Nokogiri')
        expect(external.lazy_load('Nokogiri::XML::Document#root')).to be(false)
        expect(external.lazy_gem_names).to eq(['nokogiri'])
      end

      it 'ignores paths that no skipped gem owns' do
        expect(external.lazy_load('Backport::Server')).to be(false)
        expect(external.lazy_load('String#upcase')).to be(false)
        expect(external.lazy_gem_names).to be_empty
      end

      it 'loads a dependency of a skipped gem' do
        expect(external.lazy_load('Racc::Parser')).to be(true)
        expect(external.lazy_gem_names).to eq(['racc'])
      end

      it 'evicts the least recently used gem past its limit' do
        external = described_class.new(directory, requires, direct_only: true, lazy_load: 1)
        external.lazy_load('Nokogiri')
        external.lazy_load('Racc::Parser')
        expect(external.lazy_gem_names).to eq(['racc'])
        expect(external.lazy_pins.map(&:path)).not_to include('Nokogiri')
      end

      it 'reloads an evicted gem' do
        external = described_class.new(directory, requires, direct_only: true, lazy_load: 1)
        external.lazy_load('Nokogiri')
        external.lazy_load('Racc::Parser')
        expect(external.lazy_load('Nokogiri')).to be(true)
        expect(external.lazy_gem_names).to eq(['nokogiri'])
      end

      it 'keeps a gem in use over an older one' do
        external = described_class.new(directory, requires, direct_only: true, lazy_load: 2)
        external.lazy_load('Nokogiri')
        external.lazy_load('Racc::Parser')
        external.lazy_load('Nokogiri::XML')
        expect(external.lazy_gem_names).to eq(%w[racc nokogiri])
      end

      it 'never loads an excluded gem' do
        external = described_class.new(directory, requires, direct_only: true, excluded_gems: ['nokogiri'],
                                                            lazy_load: 5)
        expect(external.lazy_load('Nokogiri')).to be(false)
      end

      it 'loads nothing for a skipped gem without a cache' do
        allow(Solargraph::Collection::Gem).to receive(:cached?).and_call_original
        allow(Solargraph::Collection::Gem).to receive(:cached?).with(having_attributes(name: 'nokogiri'))
                                                               .and_return(false)
        expect(external.lazy_load('Nokogiri')).to be(false)
      end

      it 'loads nothing lazily with a limit of 0' do
        external = described_class.new(directory, requires, direct_only: true, lazy_load: 0)
        expect(external.lazy_load('Nokogiri')).to be(false)
      end

      it 'loads nothing lazily when all gems are mapped' do
        external = described_class.new(directory, requires, lazy_load: 5)
        expect(external.lazy_load('Nokogiri')).to be(false)
        expect(external.lazy_pins).to be_empty
      end
    end

    context 'with gem caches other catalogs loaded' do
      let(:nokogiri) { Solargraph::Metagem.from_specification(Gem::Specification.find_by_name('nokogiri')) }
      let(:cache_file) { Solargraph::Collection::Gem.new(nokogiri).cache_file }

      before { Solargraph::Collection::Gem.load(nokogiri) }

      it 'releases the caches of gems it skips' do
        described_class.new(directory, requires, direct_only: true)
        expect(Solargraph::Collection.mem_cache.keys).not_to include(cache_file)
      end

      it 'releases the caches of gems it excludes' do
        described_class.new(directory, requires, excluded_gems: ['nokogiri'])
        expect(Solargraph::Collection.mem_cache.keys).not_to include(cache_file)
      end

      it 'keeps the caches when it maps all gems' do
        described_class.new(directory, ['backport'])
        expect(Solargraph::Collection.mem_cache.keys).to include(cache_file)
      end
    end
  end

  context 'with RBS collection' do
    let(:directory) { File.join('spec', 'fixtures', 'rbs_collection') }
    let(:requires) { ['addressable'] }

    it 'combines gem_rbs_collection pins' do
      external.unloaded_gems.each { |metagem| Solargraph::Collection::Gem.load(metagem) }
      external.update(requires)
      pin = external.pins.find { |pin| pin.path == 'Addressable::URI.parse' }
      expect(pin).to be_a(Solargraph::Pin::Method)
    end

    context 'with cached addressable' do
      let(:metagem) { external.loaded_gems.find { |gem| gem.name == 'addressable' } }
      let(:cache_file) { Solargraph::Collection::Gem.new(metagem).cache_file }

      before do
        external.unloaded_gems.each { |metagem| Solargraph::Collection::Gem.load(metagem) }
        external.update(requires)
      end

      it 'releases the gem pins the combination replaces' do
        expect(Solargraph::Collection.mem_cache.keys).not_to include(cache_file)
      end

      it 'loads the combined pins for the gem without caching its own again' do
        pins = Solargraph::Collection::Gem.load(metagem)
        expect(pins.map(&:source)).to include(:combined)
        expect(Solargraph::Collection.mem_cache.keys).not_to include(cache_file)
      end

      it 'reuses the combined pins for another workspace with the same collection' do
        other = described_class.new(directory, requires)
        pin = external.pins.find { |pin| pin.path == 'Addressable::URI.parse' }
        expect(other.pins.find { |pin| pin.path == 'Addressable::URI.parse' }).to equal(pin)
      end
    end
  end

  it 'tracks unresolved requires' do
    external = described_class.new(directory, ['not_a_valid_path'])
    expect(external.unresolved_requires).to eq(['not_a_valid_path'])
  end

  it 'imports all gems when bundler/require is required' do
    external = described_class.new(directory, ['bundler/require'])
    gem_names = external.loaded_gems.map(&:name)
    expect(gem_names).to include('backport')
    expect(gem_names).to include('gem-with-yard-macros')
    expect(gem_names).to include('reverse_markdown')
  end

  it 'ignores duplicate gems' do
    external = described_class.new(directory, ['backport', 'backport/version'])
    backport_method_pins = external.pins.select { |pin| pin.path == 'Backport.prepare_stdio_server' }
    expect(backport_method_pins).to be_one
  end

  it 'loads stdlib paths' do
    external = described_class.new(directory, ['net/http'])
    pin_paths = external.pins.map(&:path)
    expect(pin_paths).to include('Net::HTTP')
  end
end
