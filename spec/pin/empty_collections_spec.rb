# frozen_string_literal: true

describe Solargraph::Pin::Base do
  # Pins without anything to store
  let(:empty_array) { Solargraph::Empty::ARRAY }
  let(:empty_hash) { Solargraph::Empty::HASH }

  let(:source_map) do
    Solargraph::SourceMap.load_string(<<~RUBY, 'plain.rb')
      class Plain
        def run
          value = nil
          value
        end
      end
    RUBY
  end

  let(:method_pin) { source_map.pins.find { |pin| pin.path == 'Plain#run' } }
  let(:class_pin) { source_map.pins.find { |pin| pin.path == 'Plain' } }

  it 'shares the frozen empty collections' do
    expect(method_pin.generic_defaults).to be(empty_hash)
    expect(class_pin.generics).to be(empty_array)
    expect(method_pin.parameter_names).to be(empty_array)
    expect(method_pin.directives).to be(empty_array)
    expect(method_pin.macros).to be(empty_array)
    expect(method_pin.overloads).to be(empty_array)
    variable = Solargraph::Pin::LocalVariable.new(name: 'x', closure: method_pin, source: :code)
    expect(variable.instance_variable_get(:@assignments)).to be(empty_array)
  end

  it 'shares them in types without parameters' do
    type = Solargraph::ComplexType.parse('String').items.first

    expect([type.key_types, type.subtypes, type.all_params]).to all(be(empty_array))
  end

  it 'keeps owning its parameters, which plugins add to' do
    pin = Solargraph::Pin::Method.new(name: 'foo', closure: class_pin, source: :code)

    expect { pin.parameters.push Solargraph::Pin::Parameter.new(name: 'a', closure: pin) }
      .to change { pin.parameters.length }.from(0).to(1)
  end

  it 'leaves the original macro names alone when proxied' do
    pin = Solargraph::Pin::Method.new(name: 'foo', closure: class_pin, source: :code,
                                      comments: "@macro [attach] thing\n  @return [String]")
    names = pin.macro_names

    proxy = pin.proxy(Solargraph::ComplexType.parse('String'))

    expect(proxy.macro_names).to be_empty
    expect(pin.macro_names).to eq(names)
    expect(names).not_to be_empty
  end

  it 'still shares them after a Marshal round-trip' do
    loaded = Marshal.load(Marshal.dump(method_pin.tap(&:detach_nodes!)))

    expect(loaded.generic_defaults).to be(empty_hash)
    expect(loaded.directives).to be(empty_array)
  end
end
