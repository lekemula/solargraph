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

  describe '#gem_includes and #gem_excludes' do
    it 'are empty by default' do
      config = described_class.new(dir_path)
      expect(config.gem_includes).to eq([])
      expect(config.gem_excludes).to eq([])
    end

    it 'read the gem names' do
      File.write(File.join(dir_path, '.solargraph.yml'), "gems:\n  include: [nokogiri]\n  exclude: [twilio-ruby]\n")
      config = described_class.new(dir_path)
      expect(config.gem_includes).to eq(['nokogiri'])
      expect(config.gem_excludes).to eq(['twilio-ruby'])
    end

    it 'ignore a value that is not a list' do
      File.write(File.join(dir_path, '.solargraph.yml'), "gems:\n  exclude: twilio-ruby\n")
      expect(described_class.new(dir_path).gem_excludes).to eq([])
    end
  end

  describe '#gem_lazy_load' do
    it 'allows 50 lazily loaded gems by default' do
      expect(described_class.new(dir_path).gem_lazy_load).to eq(50)
    end

    it 'reads the limit' do
      File.write(File.join(dir_path, '.solargraph.yml'), "gems:\n  lazy_load: 3\n")
      expect(described_class.new(dir_path).gem_lazy_load).to eq(3)
    end

    it 'loads nothing lazily for a value that is not a count' do
      File.write(File.join(dir_path, '.solargraph.yml'), "gems:\n  lazy_load: many\n")
      expect(described_class.new(dir_path).gem_lazy_load).to eq(0)
    end
  end
end
