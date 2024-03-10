describe Solargraph::SourceMap do
  it "locates named path pins" do
    map = Solargraph::SourceMap.load_string(%(
      class Foo
        def bar; end
      end
    ))
    pin = map.locate_named_path_pin(2, 16)
    expect(pin.path).to eq('Foo#bar')
  end

  it "queries symbols using fuzzy matching" do
    map = Solargraph::SourceMap.load_string(%(
      class FooBar
        def baz_qux; end
      end
    ))
    expect(map.query_symbols("foo")).to eq(map.document_symbols)
    expect(map.query_symbols("foobar")).to eq(map.document_symbols)
    expect(map.query_symbols("bazqux")).to eq(map.document_symbols.select{ |pin_namespace| pin_namespace.name == "baz_qux" })
  end

  it "locates block pins" do
    map = Solargraph::SourceMap.load_string(%(
      class Foo
        100.times do
        end
      end
    ))
    pin = map.locate_block_pin(3, 0)
    expect(pin).to be_a(Solargraph::Pin::Block)
  end

  it "locates block pins from convention" do
    Solargraph::Convention.register(Class.new(Solargraph::Convention::Base) do
      def global(_source_map); Solargraph::Environ.new end
      def local(_source_map)
        Solargraph::Environ.new(pins: [
          Solargraph::Pin::Block.new(
            closure: Solargraph::Pin::Namespace.new(name: 'DynamicModule::Test'),
            location: Solargraph::Location.new(
              'test.rb',
              Solargraph::Range.from_to(2, 0, 4, 11)
            ),
          )
        ])
      end
    end)

    map = Solargraph::SourceMap.load_string(%(
      class Foo
        dynamic_module :test do
          test
        end
      end
    ), 'test.rb')
    pin = map.locate_block_pin(3, 13)
    expect(pin).to be_a(Solargraph::Pin::Block)
    expect(pin.namespace).to eq('DynamicModule::Test')
    Solargraph::Convention.clear_conventions
    Solargraph::Convention.register_defaults
  end

  it "merges comment changes" do
    map1 = Solargraph::SourceMap.load_string(%(
      class Foo
        def bar; end
      end
    ))
    map2 = Solargraph::SourceMap.load_string(%(
      class Foo
        # My bar method
        def bar; end
      end
    ))
    expect(map1.try_merge!(map2)).to be(true)
  end

  it "merges require equivalents" do
    map1 = Solargraph::SourceMap.load_string("require 'foo'")
    map2 = Solargraph::SourceMap.load_string("require 'foo' # Insignificant comment")
    expect(map1.try_merge!(map2)).to be(true)
  end

  it "does not merge require changes" do
    map1 = Solargraph::SourceMap.load_string("require 'foo'")
    map2 = Solargraph::SourceMap.load_string("require 'bar'")
    expect(map1.try_merge!(map2)).to be(false)
  end

  it "merges repaired changes" do
    source1 = Solargraph::Source.load_string(%(
      list.each do |item|
       i
      end
    ))
    updater = Solargraph::Source::Updater.new(
      nil,
      2,
      [
        Solargraph::Source::Change.new(
          Solargraph::Range.from_to(2, 8, 2, 8),
          'f '
        )
      ]
    )
    source2 = source1.synchronize(updater)
    map1 = Solargraph::SourceMap.map(source1)
    pos1 = Solargraph::Position.new(2, 8)
    pin1 = map1.pins.select{|p| p.location.range.contain?(pos1)}.first
    map2 = Solargraph::SourceMap.map(source2)
    expect(map1.try_merge!(map2)).to be(true)
    pos2 = Solargraph::Position.new(2, 10)
    pin2 = map1.pins.select{|p| p.location.range.contain?(pos2)}.first
    expect(pin1).to eq(pin2)
  end

  it 'scopes local variables correctly from root def blocks' do
    map = Solargraph::SourceMap.load_string(%(
      x = 'string'
      def foo
        x
      end
    ), 'test.rb')
    loc = Solargraph::Location.new('test.rb', Solargraph::Range.from_to(3, 9, 3, 9))
    locals = map.locals_at(loc)
    expect(locals).to be_empty
  end

  it 'scopes local variables correctly in class_eval blocks' do
    map = Solargraph::SourceMap.load_string(%(
      class Foo; end
      x = 'y'
      Foo.class_eval do
        foo = :bar
        etc
      end
    ), 'test.rb')
    locals = map.locals_at(Solargraph::Location.new('test.rb', Solargraph::Range.from_to(5, 0, 5, 0))).map(&:name)
    expect(locals).to eq(['x', 'foo'])
  end
end
