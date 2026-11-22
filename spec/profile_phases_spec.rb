# frozen_string_literal: true

require 'tmpdir'

describe Solargraph::ProfilePhases do
  let(:directory) { File.realpath(File.join('spec', 'fixtures', 'workspace')) }
  let(:host) { Solargraph::LanguageServer::Host.new }
  let(:phases) { described_class.new(host) }
  let(:library) { host.libraries.first }
  let(:other_uri) { Solargraph::LanguageServer::UriHelpers.file_to_uri(File.join(directory, 'lib', 'other.rb')) }

  # @param lib [Solargraph::Library]
  # @return [Integer]
  def cataloged_files lib
    lib.send(:api_map).source_maps.length
  end

  after { host.stop }

  describe '#map' do
    it 'returns once every file is mapped, before the first catalog starts' do
      phases.map(directory)

      expect(library).to be_mapped
      expect(cataloged_files(library)).to eq(0)
    ensure
      phases.catalog
    end
  end

  describe '#catalog' do
    it 'returns once the first catalog has finished' do
      phases.map(directory)
      phases.catalog

      expect(library).to be_synchronized
      expect(cataloged_files(library)).to eq(library.workspace.filenames.length)
    end

    it 'catalogs a library with no files to map' do
      empty = Dir.mktmpdir
      phases.map(empty)
      phases.catalog

      expect(library).to be_synchronized
    ensure
      FileUtils.rm_rf(empty)
    end
  end

  describe '#definition' do
    it 'resolves the definition against the synchronized library' do
      phases.map(directory)
      phases.catalog

      allow(library).to receive(:catalog).and_call_original
      result = phases.definition(other_uri, 4, 10)

      expect(result.map { |loc| loc[:uri] }).to eq(
        [Solargraph::LanguageServer::UriHelpers.file_to_uri(File.join(directory, 'lib', 'thing.rb'))]
      )
      expect(library).not_to have_received(:catalog)
    end
  end
end
