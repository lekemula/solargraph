# frozen_string_literal: true

describe Solargraph::ApiMap::Store do
  it 'indexes multiple pinsets' do
    foo_pin = Solargraph::Pin::Namespace.new(name: 'Foo')
    bar_pin = Solargraph::Pin::Namespace.new(name: 'Bar')
    store = described_class.new([foo_pin], [bar_pin])

    expect(store.get_path_pins('Foo')).to eq([foo_pin])
    expect(store.get_path_pins('Bar')).to eq([bar_pin])
  end

  it 'indexes empty pinsets' do
    foo_pin = Solargraph::Pin::Namespace.new(name: 'Foo')

    store = described_class.new([], [foo_pin])
    expect(store.get_path_pins('Foo')).to eq([foo_pin])
  end

  it 'updates existing pinsets' do
    foo_pin = Solargraph::Pin::Namespace.new(name: 'Foo')
    bar_pin = Solargraph::Pin::Namespace.new(name: 'Bar')
    baz_pin = Solargraph::Pin::Namespace.new(name: 'Baz')
    store = described_class.new([foo_pin], [bar_pin])
    store.update([foo_pin], [baz_pin])

    expect(store.get_path_pins('Foo')).to eq([foo_pin])
    expect(store.get_path_pins('Baz')).to eq([baz_pin])
    expect(store.get_path_pins('Bar')).to be_empty
  end

  it 'updates new pinsets' do
    foo_pin = Solargraph::Pin::Namespace.new(name: 'Foo')
    bar_pin = Solargraph::Pin::Namespace.new(name: 'Bar')
    store = described_class.new([foo_pin])
    store.update([foo_pin], [bar_pin])

    expect(store.get_path_pins('Foo')).to eq([foo_pin])
    expect(store.get_path_pins('Bar')).to eq([bar_pin])
  end

  it 'updates empty stores' do
    foo_pin = Solargraph::Pin::Namespace.new(name: 'Foo')
    bar_pin = Solargraph::Pin::Namespace.new(name: 'Bar')
    store = described_class.new
    store.update([foo_pin, bar_pin])

    expect(store.get_path_pins('Foo')).to eq([foo_pin])
    expect(store.get_path_pins('Bar')).to eq([bar_pin])
  end

  it 'counts pins of every pinset' do
    foo_pin = Solargraph::Pin::Namespace.new(name: 'Foo')
    bar_pin = Solargraph::Pin::Namespace.new(name: 'Bar')
    store = described_class.new([foo_pin], [], [bar_pin])

    expect(store.pin_count).to eq(2)
    expect(store.pins).to eq([foo_pin, bar_pin])
  end

  it 'drops lookups memoized for replaced pinsets' do
    foo_pin = Solargraph::Pin::Namespace.new(name: 'Foo')
    one = Solargraph::Pin::Method.new(name: 'one', closure: foo_pin, scope: :instance)
    two = Solargraph::Pin::Method.new(name: 'two', closure: foo_pin, scope: :instance)
    three = Solargraph::Pin::Method.new(name: 'three', closure: foo_pin, scope: :instance)
    store = described_class.new([foo_pin, one], [two])
    expect(store.get_methods('Foo').map(&:name)).to eq(%w[one two])

    store.update([foo_pin, one], [three])
    expect(store.get_methods('Foo').map(&:name)).to eq(%w[one three])
  end

  it 'runs the update block against the updated pinsets' do
    foo_pin = Solargraph::Pin::Namespace.new(name: 'Foo')
    bar_pin = Solargraph::Pin::Namespace.new(name: 'Bar')
    baz_pin = Solargraph::Pin::Namespace.new(name: 'Baz')
    store = described_class.new([foo_pin], [])
    seen = nil
    store.update([foo_pin], [bar_pin]) do
      seen = store.get_path_pins('Bar')
      [baz_pin]
    end

    expect(seen).to eq([bar_pin])
    expect(store.get_path_pins('Baz')).to eq([baz_pin])
  end

  describe 'reference pins' do
    let(:map) do
      Solargraph::SourceMap.load_string(%(
        module Inc; end
        module Ext; end
        module Pre; end
        module Hook; def self.included(base); end; end
        class Foo
          include Inc
          extend Ext
          prepend Pre
        end
      ), 'test.rb')
    end

    let(:store) do
      other = Solargraph::Pin::Namespace.new(name: 'Other')
      described_class.new(map.pins, [other], [], [other]).tap do |store|
        store.update(map.pins, [other], [other], [other]) { [] }
        store.update(map.pins, [other], [other], []) { [] }
      end
    end

    it 'returns each include once' do
      expect(store.get_includes('Foo').map(&:name)).to eq(['Inc'])
    end

    it 'returns each extend once' do
      expect(store.get_extends('Foo').map(&:name)).to eq(['Ext'])
    end

    it 'returns each prepend once' do
      expect(store.get_prepends('Foo').map(&:name)).to eq(['Pre'])
    end

    it 'returns each included mixin once' do
      mixin = Solargraph::Pin::Reference::IncludedMixin.new(name: 'Mixin', keyword: :include, closure: map.first_pin('Foo'))
      store = described_class.new(map.pins + [mixin], [], [])
      store.update(map.pins + [mixin], [Solargraph::Pin::Namespace.new(name: 'Other')], [])
      expect(store.get_included_mixins('Foo').map(&:name)).to eq(['Mixin'])
    end
  end

  # @todo This will become #get_superclass
  describe '#get_superclass' do
    it 'returns simple superclasses' do
      map = Solargraph::SourceMap.load_string(%(
        class Foo; end
        class Bar < Foo; end
      ), 'test.rb')
      store = described_class.new(map.pins)
      ref = store.get_superclass('Bar')
      expect(ref.name).to eq('Foo')
    end

    it 'returns Boolean superclass' do
      store = described_class.new
      ref = store.get_superclass('TrueClass')
      expect(ref.name).to eq('Boolean')
    end
  end

  describe '#fqns_pins' do
    let(:store) do
      methods = Array.new(2_000) { |i| Solargraph::Pin::Method.new(name: "m#{i}", closure: Solargraph::Pin::ROOT_PIN) }
      described_class.new(methods + [Solargraph::Pin::Namespace.new(name: 'Foo')])
    end

    it 'finds namespaces among many root pins' do
      expect(store.fqns_pins('Foo').map(&:path)).to eq(['Foo'])
      expect(store.fqns_pins('Bar')).to be_empty
    end

    it 'keeps memoized results sized to their contents' do
      require 'objspace'
      expect(ObjectSpace.memsize_of(store.fqns_pins('Foo'))).to be < 1_000
      expect(ObjectSpace.memsize_of(store.fqns_pins('Bar'))).to be < 1_000
    end
  end

  describe '#demand' do
    let(:foo_pin) { Solargraph::Pin::Namespace.new(name: 'Foo') }

    it 'is asked for a path before a lookup reads it' do
      store = described_class.new([foo_pin])
      asked = []
      store.demand = ->(path) { asked.push path }
      store.get_path_pins('Foo')
      store.get_methods('Bar')
      expect(asked).to eq(%w[Foo Bar])
    end

    it 'is not asked while the store updates' do
      store = described_class.new([foo_pin], [])
      asked = []
      store.demand = ->(path) { asked.push path }
      store.update([foo_pin], [Solargraph::Pin::Namespace.new(name: 'Bar')]) do
        store.get_path_pins('Foo')
        []
      end
      expect(asked).to be_empty
    end
  end

  describe '#update_layer' do
    it 'replaces one pinset and keeps the pins of the last update block' do
      foo_pin = Solargraph::Pin::Namespace.new(name: 'Foo')
      bar_pin = Solargraph::Pin::Namespace.new(name: 'Bar')
      baz_pin = Solargraph::Pin::Namespace.new(name: 'Baz')
      top_pin = Solargraph::Pin::Namespace.new(name: 'Top')
      store = described_class.new
      store.update([foo_pin], [bar_pin], []) { [top_pin] }
      store.update_layer(1, [baz_pin])
      expect(store.get_path_pins('Bar')).to be_empty
      expect(store.get_path_pins('Baz')).to eq([baz_pin])
      expect(store.get_path_pins('Top')).to eq([top_pin])
    end
  end
end
