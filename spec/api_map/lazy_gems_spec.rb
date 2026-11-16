# frozen_string_literal: true

describe Solargraph::ApiMap do
  let(:gem_loading) { 'direct' }
  let(:lazy_load) { 5 }
  let(:config) do
    config = Solargraph::Workspace::Config.new(directory)
    allow(config).to receive_messages(gem_loading: gem_loading, gem_lazy_load: lazy_load)
    config
  end
  let(:workspace) { Solargraph::Workspace.new(directory, config) }

  before(:all) do # rubocop:disable RSpec/BeforeAfterAll
    %w[backport reverse_markdown nokogiri racc].each do |name|
      metagem = Solargraph::Metagem.from_specification(Gem::Specification.find_by_name(name))
      Solargraph::Collection::Gem.load(metagem) unless Solargraph::Collection::Gem.cached?(metagem)
    end
  end

  # @return [String]
  def directory
    File.realpath(File.join('spec', 'fixtures', 'external_bundled_gem'))
  end

  # @return [String]
  def filename
    File.join(directory, 'lazy.rb')
  end

  # @param code [String]
  # @param requires [Array<String>]
  # @param api_map [Solargraph::ApiMap]
  # @return [Solargraph::ApiMap]
  def catalog code, requires: ['reverse_markdown'], api_map: described_class.new
    source = Solargraph::Source.load_string(code, filename)
    api_map.catalog Solargraph::Bench.new(workspace: workspace, source_maps: [Solargraph::SourceMap.map(source)],
                                          external_requires: requires)
  end

  it 'leaves skipped gems out until something refers to them' do
    api_map = catalog("doc = Nokogiri::HTML::Document.new\n")
    expect(api_map.external.lazy_gem_names).to be_empty
    expect(api_map.pins.map(&:path)).not_to include('Nokogiri::HTML::Document')
  end

  it 'answers a constant reference into a skipped gem' do
    api_map = catalog("doc = Nokogiri::HTML::Document.new\n")
    expect(api_map.get_path_pins('Nokogiri::HTML::Document')).not_to be_empty
    expect(api_map.external.lazy_gem_names).to eq(['nokogiri'])
  end

  it 'infers the type of a skipped gem class' do
    api_map = catalog("doc = Nokogiri::XML::Document.new\ndoc\n")
    expect(api_map.clip_at(filename, [1, 1]).infer.to_s).to eq('Nokogiri::XML::Document')
  end

  it 'lists the methods of a skipped gem class' do
    api_map = catalog("doc = Nokogiri::XML::Document.new\n")
    expect(api_map.get_methods('Nokogiri::XML::Document').map(&:name)).to include('create_element')
  end

  it 'maps a skipped gem that a require added later asks for' do
    api_map = catalog("x = 1\n")
    expect(api_map.external.loaded_gems.map(&:name)).not_to include('nokogiri')
    catalog("require 'nokogiri'\n", requires: %w[reverse_markdown nokogiri], api_map: api_map)
    expect(api_map.external.loaded_gems.map(&:name)).to include('nokogiri')
    expect(api_map.external.lazy_gem_names).to be_empty
  end

  context 'with room for one lazily loaded gem' do
    let(:lazy_load) { 1 }

    it 'evicts the pins of the least recently used gem' do
      api_map = catalog("x = 1\n")
      api_map.get_path_pins('Nokogiri::HTML::Document')
      api_map.get_path_pins('Racc::Parser')
      expect(api_map.external.lazy_gem_names).to eq(['racc'])
      expect(api_map.pins.map(&:path)).not_to include('Nokogiri::HTML::Document')
    end

    it 'reloads an evicted gem on its next reference' do
      api_map = catalog("x = 1\n")
      api_map.get_path_pins('Nokogiri::HTML::Document')
      api_map.get_path_pins('Racc::Parser')
      expect(api_map.get_path_pins('Nokogiri::HTML::Document')).not_to be_empty
    end
  end

  context 'when all gems are mapped' do
    let(:gem_loading) { 'all' }

    it 'maps the transitive gems up front and loads none lazily' do
      api_map = catalog("x = 1\n")
      expect(api_map.external.loaded_gems.map(&:name)).to include('nokogiri')
      api_map.get_path_pins('Nokogiri::HTML::Document')
      expect(api_map.external.lazy_gem_names).to be_empty
    end
  end
end
