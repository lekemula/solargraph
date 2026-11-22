# frozen_string_literal: true

describe Solargraph::NodeRef do
  let(:code) { "class A\n  def foo\n    bar(1)\n  end\nend\n" }
  let(:root) { Solargraph::Parser.parse(code, 'file.rb') }
  let(:def_node) { root.children[2] }

  it 'replaces a node of the given file with a reference' do
    ref = described_class.detach(def_node, 'file.rb')
    expect(ref).to be_a(described_class)
    expect(ref.filename).to eq('file.rb')
    expect(ref.type).to eq(:def)
    expect(ref.find_in(root)).to equal(def_node)
  end

  it 'keeps nodes of other files' do
    expect(described_class.detach(def_node, 'other.rb')).to equal(def_node)
  end

  it 'keeps nodes without a location' do
    node = Parser::AST::Node.new(:nil)
    expect(described_class.detach(node, 'file.rb')).to equal(node)
  end

  it 'drops nodes when no file is given' do
    expect(described_class.detach(def_node, nil)).to be_nil
  end

  it 'tells nested nodes with the same range apart by type' do
    root = Solargraph::Parser.parse('foo', 'file.rb')
    ref = described_class.detach(root, 'file.rb')
    expect(ref.find_in(root)).to equal(root)
  end

  it 'compares references by position' do
    a = described_class.detach(def_node, 'file.rb')
    b = described_class.detach(Solargraph::Parser.parse(code, 'file.rb').children[2], 'file.rb')
    expect(a).to eq(b)
    expect(a.hash).to eq(b.hash)
  end

  it 'gives the same key for a node and its reference' do
    expect(described_class.key(def_node)).to eq(described_class.key(described_class.detach(def_node, 'file.rb')))
  end
end
