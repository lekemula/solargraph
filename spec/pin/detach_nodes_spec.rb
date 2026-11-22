# frozen_string_literal: true

require 'tmpdir'

describe Solargraph::Pin::Base, '#detach_nodes!' do
  let(:dir) { File.realpath(Dir.mktmpdir) }
  let(:file) { File.join(dir, 'file.rb') }
  let(:code) do
    <<~RUBY
      class Foo
        def bar
          @baz = [1, 2]
          a, b = @baz
          if a
            b
          end
          [a].each { |x| x }
        end
      end
    RUBY
  end
  let(:pins) do
    File.write(file, code)
    map = Solargraph::SourceMap.load(file)
    map.pins + map.locals
  end

  before { Solargraph::SourceCache.reset! }

  after do
    Solargraph::SourceCache.reset!
    FileUtils.remove_entry dir
  end

  # @param pins [Array<Solargraph::Pin::Base>]
  # @return [Array<Solargraph::Pin::Base>]
  def detach pins
    Solargraph::SourceCache.instance.register file
    pins.each { |pin| pin.detach_nodes!(reload_from: file) }
  end

  it 'reloads method nodes through the source cache' do
    method = pins.find { |pin| pin.path == 'Foo#bar' }
    original = method.node
    detach pins
    expect(method.instance_variable_get(:@node)).to be_a(Solargraph::NodeRef)
    expect(method.node).to eq(original)
  end

  it 'reloads variable assignments' do
    ivar = pins.find { |pin| pin.name == '@baz' }
    local = pins.find { |pin| pin.name == 'b' && pin.is_a?(Solargraph::Pin::LocalVariable) }
    detach pins
    expect(ivar.assignment.type).to eq(:array)
    expect(local.mass_assignment.first.type).to eq(:ivar)
  end

  it 'reloads block nodes and receivers' do
    block = pins.find { |pin| pin.is_a?(Solargraph::Pin::Block) }
    detach pins
    expect(block.node.type).to eq(:block)
    expect(block.receiver.type).to eq(:send)
  end

  it 'keeps only the end position of other compound statements' do
    statement = pins.find { |pin| pin.instance_of?(Solargraph::Pin::CompoundStatement) }
    position = statement.end_position
    detach pins
    expect(statement.node).to be_nil
    expect(statement.end_position).to eq(position)
  end

  it 'compares detached method pins by location' do
    method = pins.find { |pin| pin.path == 'Foo#bar' }
    copy = method.dup
    detach [method]
    expect(method).to eq(copy)
  end

  it 'returns no node once the file changed on disk' do
    method = pins.find { |pin| pin.path == 'Foo#bar' }
    detach pins
    File.write(file, "#{code}\n# changed\n")
    expect(method.node).to be_nil
  end

  it 'keeps nodes of other files' do
    method = pins.find { |pin| pin.path == 'Foo#bar' }
    method.detach_nodes!(reload_from: File.join(dir, 'other.rb'))
    expect(method.instance_variable_get(:@node)).to be_a(Parser::AST::Node)
  end
end
