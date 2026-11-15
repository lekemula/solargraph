# frozen_string_literal: true

describe Solargraph::Pin::Constant do
  it 'resolves constant paths' do
    source = Solargraph::Source.new(%(
      class Foo
        BAR = 'bar'
      end
    ))
    map = Solargraph::SourceMap.map(source)
    pin = map.pins.select { |pin| pin.name == 'BAR' }.first
    expect(pin.path).to eq('Foo::BAR')
  end

  it 'is a constant kind' do
    source = Solargraph::Source.new(%(
      class Foo
        BAR = 'bar'
      end
    ))
    map = Solargraph::SourceMap.map(source)
    pin = map.pins.select { |pin| pin.name == 'BAR' }.first
    expect(pin.completion_item_kind).to eq(Solargraph::LanguageServer::CompletionItemKinds::CONSTANT)
    expect(pin.symbol_kind).to eq(Solargraph::LanguageServer::SymbolKinds::CONSTANT)
  end

  context 'with detached nodes' do
    let(:map) do
      Solargraph::SourceMap.load_string(%(
        module Outer
          Error = Inner::Error
          LIMIT = 10
        end
      ), 'test.rb')
    end
    let(:pins) { map.pins.grep(described_class) }

    it 'keeps the name its value refers to' do
      pins.each(&:detach_nodes!)
      expect(pins.map(&:alias_name)).to eq(%w[Inner::Error 10])
    end

    it 'drops the assignment node' do
      pins.each(&:detach_nodes!)
      expect(pins.map(&:assignment)).to eq([nil, nil])
    end

    it 'keeps the alias name when combined' do
      detached = pins.first.dup.detach_nodes!
      expect(detached.combine_with(pins.first.dup.detach_nodes!).alias_name).to eq('Inner::Error')
    end
  end
end
