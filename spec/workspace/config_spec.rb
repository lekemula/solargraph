# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

describe Solargraph::Workspace::Config do
  let(:dir_path) { File.realpath(Dir.mktmpdir) }

  after { FileUtils.remove_entry(dir_path) }

  it 'includes .rb files by default' do
    file = File.join(dir_path, 'file.rb')
    File.write(file, 'exit')
    config = described_class.new(dir_path)
    expect(config.calculated).to include(file)
  end

  it 'includes .rb files in subdirectories by default' do
    Dir.mkdir(File.join(dir_path, 'lib'))
    file = File.join(dir_path, 'lib', 'file.rb')
    File.write(file, 'exit')
    config = described_class.new(dir_path)
    expect(config.calculated).to include(file)
  end

  it 'excludes test directories by default' do
    Dir.mkdir(File.join(dir_path, 'test'))
    file = File.join(dir_path, 'test', 'file.rb')
    File.write(file, 'exit')
    config = described_class.new(dir_path)
    expect(config.calculated).not_to include(file)
  end

  it 'excludes spec directories by default' do
    Dir.mkdir(File.join(dir_path, 'spec'))
    file = File.join(dir_path, 'spec', 'file.rb')
    File.write(file, 'exit')
    config = described_class.new(dir_path)
    expect(config.calculated).not_to include(file)
  end

  it 'excludes vendor directories by default' do
    Dir.mkdir(File.join(dir_path, 'vendor'))
    file = File.join(dir_path, 'vendor', 'file.rb')
    File.write(file, 'exit')
    config = described_class.new(dir_path)
    expect(config.calculated).not_to include(file)
  end

  it 'includes base reporters by default' do
    config = described_class.new(dir_path)
    expect(config.reporters).to include('rubocop')
    expect(config.reporters).to include('require_not_found')
  end

  describe '#gem_loading' do
    it 'loads all gems by default' do
      expect(described_class.new(dir_path).gem_loading).to eq('all')
    end

    it 'reads the direct mode' do
      File.write(File.join(dir_path, '.solargraph.yml'), "gems:\n  load: direct\n")
      expect(described_class.new(dir_path).gem_loading).to eq('direct')
    end

    it 'loads all gems when the gems key has no mode' do
      File.write(File.join(dir_path, '.solargraph.yml'), "gems: {}\n")
      expect(described_class.new(dir_path).gem_loading).to eq('all')
    end

    it 'loads all gems for an unknown mode' do
      File.write(File.join(dir_path, '.solargraph.yml'), "gems:\n  load: some\n")
      expect(described_class.new(dir_path).gem_loading).to eq('all')
    end
  end
end
