# frozen_string_literal: true

require 'tmpdir'

describe Solargraph::SourceCache do
  let(:cache) { described_class.new(2) }
  let(:dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry dir }

  # @param name [String]
  # @param code [String]
  # @return [String]
  def write_file name, code
    path = File.join(dir, name)
    File.write(path, code)
    path
  end

  it 'loads nothing for files it has no stamp for' do
    file = write_file('a.rb', 'class A; end')
    expect(cache.fetch(file)).to be_nil
  end

  it 'reloads a registered file from disk' do
    file = write_file('a.rb', 'class A; end')
    cache.register file
    source = cache.fetch(file)
    expect(source.code).to eq('class A; end')
    expect(source.node.type).to eq(:class)
  end

  it 'keeps the most recently used sources up to its size' do
    files = %w[a b c].map { |name| write_file("#{name}.rb", "class #{name.upcase}; end") }
    files.each { |file| cache.register file }
    first = cache.fetch(files[0])
    cache.fetch(files[1])
    expect(cache.fetch(files[0])).to be(first)
    cache.fetch(files[2])
    expect(cache.cached_filenames).to eq([files[0], files[2]])
    expect(cache.fetch(files[0])).to be(first)
  end

  it 'keeps open files outside the LRU' do
    files = %w[a b c].map { |name| write_file("#{name}.rb", "class #{name.upcase}; end") }
    files.each { |file| cache.register file }
    cache.open files[0]
    opened = cache.fetch(files[0])
    cache.fetch(files[1])
    cache.fetch(files[2])
    expect(cache.cached_filenames).to eq([files[1], files[2]])
    expect(cache.fetch(files[0])).to be(opened)
  end

  it 'refuses a file changed since it was registered and reports it stale' do
    file = write_file('a.rb', 'class A; end')
    cache.register file
    File.write(file, 'class A; def foo; end; end')
    expect(cache.fetch(file)).to be_nil
    expect(cache.take_stale { true }).to eq([file])
    expect(cache.take_stale { true }).to be_empty
  end

  it 'refuses a deleted file' do
    file = write_file('a.rb', 'class A; end')
    cache.register file
    File.delete file
    expect(cache.fetch(file)).to be_nil
    expect(cache.take_stale { true }).to eq([file])
  end

  it 'drops the cached copy when a file is registered again' do
    file = write_file('a.rb', 'class A; end')
    cache.register file
    first = cache.fetch(file)
    cache.register file
    expect(cache.fetch(file)).not_to be(first)
  end

  it 'forgets files' do
    file = write_file('a.rb', 'class A; end')
    cache.register file
    cache.fetch(file)
    cache.forget file
    expect(cache.fetch(file)).to be_nil
    expect(cache.cached_filenames).to be_empty
  end

  it 'finds nodes by reference' do
    file = write_file('a.rb', "class A\n  def foo\n    1\n  end\nend\n")
    node = Solargraph::Source.load(file).node.children[2]
    ref = Solargraph::NodeRef.detach(node, file)
    cache.register file
    found = cache.node(ref)
    expect(found).to eq(node)
    expect(Solargraph::Range.from_node(found)).to eq(Solargraph::Range.from_node(node))
  end
end
