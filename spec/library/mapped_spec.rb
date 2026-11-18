# frozen_string_literal: true

require 'tmpdir'

describe Solargraph::Library, '#mapped?' do
  let(:dir) { File.realpath(Dir.mktmpdir) }
  let(:first) { File.join(dir, 'a.rb') }
  let(:second) { File.join(dir, 'b.rb') }
  let(:third) { File.join(dir, 'c.rb') }
  let(:library) { described_class.new(Solargraph::Workspace.new(dir)) }

  before do
    File.write(first, "class A; end\n")
    File.write(second, "class B; end\n")
    File.write(third, "class C; end\n")
  end

  after { FileUtils.remove_entry dir }

  # @return [Array<String>]
  def map_all
    mapped = []
    while (map = library.next_map)
      mapped.push map.filename
    end
    mapped
  end

  it 'is false until every workspace file is mapped' do
    expect(library).not_to be_mapped
    library.next_map
    library.next_map
    expect(library).not_to be_mapped
    library.next_map
    expect(library).to be_mapped
  end

  it 'maps the files in workspace order' do
    expect(map_all).to eq(library.workspace.filenames)
  end

  it 'is true for an empty workspace' do
    empty = described_class.new(Solargraph::Workspace.new(Dir.mktmpdir))
    expect(empty).to be_mapped
    expect(empty.next_map).to be(false)
  end

  it 'does not list the workspace files again while the workspace is unchanged' do
    library.next_map
    allow(library.workspace).to receive(:filenames).and_call_original
    library.mapped?
    map_all
    library.mapped?
    expect(library.workspace).not_to have_received(:filenames)
  end

  it 'maps a file created in the workspace while mapping' do
    library.next_map
    created = File.join(dir, 'd.rb')
    File.write(created, "class D; end\n")
    library.workspace.merge Solargraph::Source.load(created)
    expect(map_all).to include(created)
    expect(library).to be_mapped
  end

  it 'counts a file created from disk as mapped' do
    map_all
    created = File.join(dir, 'd.rb')
    File.write(created, "class D; end\n")
    library.create_from_disk created
    expect(library).to be_mapped
  end

  it 'is mapped when the last pending file gets deleted' do
    library.next_map
    library.next_map
    library.delete third
    expect(library).to be_mapped
    expect(library.next_map).to be(false)
  end

  it 'is not mapped after a mapped file is deleted and created again' do
    map_all
    library.delete first
    library.workspace.merge Solargraph::Source.load(first)
    expect(library).not_to be_mapped
    expect(map_all).to eq([first])
  end

  it 'ignores attached files that are not in the workspace' do
    outside = Solargraph::Source.load_string("class Outside; end\n", '/outside/file.rb')
    library.attach outside
    expect(library).not_to be_mapped
    map_all
    expect(library).to be_mapped
    library.detach outside.filename
    library.close outside.filename
    expect(library).to be_mapped
  end

  it 'counts files mapped by a merge' do
    library.merge Solargraph::Source.load(first)
    library.merge Solargraph::Source.load(second)
    expect(map_all).to eq([third])
  end

  it 'is mapped after map!' do
    library.map!
    expect(library).to be_mapped
    expect(library.next_map).to be(false)
  end

  it 'stays unmapped when the next source cannot be loaded' do
    allow(library.workspace).to receive(:source).and_call_original
    allow(library.workspace).to receive(:source).with(first).and_return(nil)
    expect(library.next_map).to be(false)
    expect(library).not_to be_mapped
  end

  it 'catalogs once, when the last file is mapped' do
    allow(library).to receive(:catalog).and_call_original
    library.next_map
    library.next_map
    expect(library).not_to have_received(:catalog)
    library.next_map
    expect(library).to have_received(:catalog).once
    library.next_map
    expect(library).to have_received(:catalog).once
  end
end
