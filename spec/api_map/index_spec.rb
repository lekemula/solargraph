# frozen_string_literal: true

describe Solargraph::ApiMap::Index do
  subject(:output_pins) { described_class.new(input_pins).pins }

  describe '#map_overrides' do
    let(:foo_class) do
      Solargraph::Pin::Namespace.new(name: 'Foo')
    end

    let(:foo_initialize) do
      init = Solargraph::Pin::Method.new(name: 'initialize',
                                         scope: :instance,
                                         parameters: [],
                                         closure: foo_class)
      # no return type specified
      param = Solargraph::Pin::Parameter.new(name: 'bar',
                                             closure: init)
      init.parameters << param
      init
    end

    let(:foo_new) do
      init = Solargraph::Pin::Method.new(name: 'new',
                                         scope: :class,
                                         parameters: [],
                                         closure: foo_class)
      # no return type specified
      param = Solargraph::Pin::Parameter.new(name: 'bar',
                                             closure: init)
      init.parameters << param
      init
    end

    let(:foo_override) do
      Solargraph::Pin::Reference::Override.from_comment('Foo#initialize',
                                                        '@param [String] bar')
    end

    let(:input_pins) do
      [
        foo_initialize,
        foo_new,
        foo_override
      ]
    end

    it 'has a docstring to process on override' do
      expect(foo_override.docstring.tags).to be_empty
    end

    it 'overrides .new method' do
      method_pin = output_pins.find { |pin| pin.path == 'Foo.new' }
      first_parameter = method_pin.parameters.first
      expect(first_parameter.return_type.tag).to eq('String')
    end

    it 'overrides #initialize method in signature' do
      method_pin = output_pins.find { |pin| pin.path == 'Foo#initialize' }
      first_parameter = method_pin.parameters.first
      expect(first_parameter.return_type.tag).to eq('String')
    end
  end

  describe '#map_overrides on a constant' do
    let(:baz_constant) do
      Solargraph::Pin::Constant.new(name: 'BAZ',
                                    closure: Solargraph::Pin::ROOT_PIN,
                                    comments: '@return [String]')
    end

    let(:baz_override) do
      Solargraph::Pin::Reference::Override.from_comment('BAZ', '@return [Integer]')
    end

    let(:input_pins) { [baz_constant, baz_override] }

    it 'does not raise on a pin without signatures' do
      expect { output_pins }.not_to raise_error
    end

    it 'redefines the return type of the constant' do
      constant_pin = output_pins.find { |pin| pin.path == 'BAZ' }
      expect(constant_pin.return_type.tag).to eq('Integer')
    end
  end

  describe 'with chained layers' do
    let(:foo) { Solargraph::Pin::Namespace.new(name: 'Foo') }
    let(:bar) { Solargraph::Pin::Namespace.new(name: 'Bar') }

    # @param name [String]
    # @param closure [Solargraph::Pin::Closure]
    # @param comments [String]
    def method_pin name, closure, comments = ''
      Solargraph::Pin::Method.new(name: name, closure: closure, scope: :instance, comments: comments)
    end

    # @param namespace [Solargraph::Pin::Namespace]
    # @param mixin [String]
    def include_ref namespace, mixin
      Solargraph::Pin::Reference::Include.new(name: mixin, closure: namespace)
    end

    describe 'lookups' do
      let(:base) { described_class.new([foo, method_pin('one', foo)]) }
      let(:top) { base.merge([bar, method_pin('two', foo)]) }

      def foo_one = base.path_pin_hash['Foo#one'].first
      def foo_two = top.path_pin_hash['Foo#two'].first

      it 'finds pins of every layer' do
        expect(top.path_pin_hash['Foo#one']).to eq([foo_one])
        expect(top.path_pin_hash['Bar']).to eq([bar])
      end

      it 'concatenates hits from several layers bottom layer first' do
        expect(top.namespace_hash['Foo']).to eq([foo_one, foo_two])
      end

      it 'returns an empty array on a miss' do
        expect(top.path_pin_hash['Nope']).to eq([])
      end

      it 'reports keys of every layer' do
        expect(top.namespace_hash.key?('Foo')).to be(true)
        expect(top.namespace_hash.key?('Nope')).to be(false)
      end

      it 'selects pins by class across layers' do
        expect(top.pins_by_class(Solargraph::Pin::Method).to_a).to contain_exactly(foo_one, foo_two)
      end

      it 'lists all pins bottom layer first' do
        expect(top.pins).to eq([foo, foo_one, bar, foo_two])
      end

      it 'counts all pins without listing them' do
        expect(top.pin_count).to eq(4)
      end

      it 'does not see pins of a layer above' do
        top
        expect(base.path_pin_hash['Bar']).to eq([])
        expect(base.namespace_hash['Foo']).to eq([foo_one])
        expect(base.pin_count).to eq(2)
      end

      it 'keeps sibling layers apart' do
        foo_three = method_pin('three', foo)
        sibling = base.merge([foo_three])
        expect(top.namespace_hash['Foo']).to eq([foo_one, foo_two])
        expect(sibling.namespace_hash['Foo']).to eq([foo_one, foo_three])
      end

      it 'does not mutate lower layers when combining hits' do
        top.namespace_hash['Foo'] << :junk
        expect(base.namespace_hash['Foo']).to eq([foo_one])
      end
    end

    describe 'reference pins' do
      it 'holds each reference pin once however many layers sit above it' do
        ref = include_ref(foo, 'Mixin')
        top = described_class.new([foo, ref]).merge([bar]).merge([]).merge([method_pin('one', bar)])
        expect(top.include_references['Foo']).to eq([ref])
      end

      it 'combines references from several layers' do
        low = include_ref(foo, 'Low')
        high = include_ref(foo, 'High')
        top = described_class.new([foo, low]).merge([high])
        expect(top.include_references['Foo']).to eq([low, high])
      end
    end

    describe 'type aliases' do
      it 'lets a higher layer redefine an alias' do
        low = Solargraph::Pin::Reference::TypeAlias.new(name: 'Thing', return_type: Solargraph::ComplexType.parse('String'))
        high = Solargraph::Pin::Reference::TypeAlias.new(name: 'Thing', return_type: Solargraph::ComplexType.parse('Integer'))
        top = described_class.new([low]).merge([high])
        expect(top.alias_hash['Thing'].tag).to eq('Integer')
      end
    end

    describe 'macro method names' do
      it 'accumulates names from every layer' do
        low = method_pin('low', foo, "@!macro [attach] low_macro\n  @return [String]")
        high = method_pin('high', foo, "@!macro [attach] high_macro\n  @return [String]")
        top = described_class.new([low]).merge([]).merge([high])
        expect(top.macro_method_names.to_a).to contain_exactly('low', 'high')
        expect(top.macro_method_name_pins['low']).to eq([low])
      end
    end

    describe 'overrides across layers' do
      # @param path [String]
      # @param type [String]
      def return_override path, type
        Solargraph::Pin::Reference::Override.from_comment(path, "@return [#{type}]")
      end

      it 'applies an override of a higher layer to a pin of a lower layer' do
        pin = method_pin('one', foo)
        described_class.new([foo, pin]).merge([return_override('Foo#one', 'String')])
        expect(pin.return_type.tag).to eq('String')
      end

      it 'applies an override of a lower layer to a pin of a higher layer' do
        pin = method_pin('one', foo)
        described_class.new([foo, return_override('Foo#one', 'String')]).merge([pin])
        expect(pin.return_type.tag).to eq('String')
      end

      it 'lets the higher layer win when the pin is below both overrides' do
        pin = method_pin('one', foo)
        described_class.new([foo, pin, return_override('Foo#one', 'String')])
                       .merge([return_override('Foo#one', 'Integer')])
        expect(pin.return_type.tag).to eq('Integer')
      end

      it 'lets the higher layer win when the pin is above both overrides' do
        pin = method_pin('one', foo)
        described_class.new([foo, return_override('Foo#one', 'String')])
                       .merge([return_override('Foo#one', 'Integer')])
                       .merge([pin])
        expect(pin.return_type.tag).to eq('Integer')
      end

      it 'lets the higher layer win when the pin is between the overrides' do
        pin = method_pin('one', foo)
        described_class.new([foo, return_override('Foo#one', 'String')])
                       .merge([pin])
                       .merge([return_override('Foo#one', 'Integer')])
        expect(pin.return_type.tag).to eq('Integer')
      end
    end
  end
end
