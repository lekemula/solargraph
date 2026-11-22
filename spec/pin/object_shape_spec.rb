# frozen_string_literal: true

require 'objspace'

# Ruby gives every object one shape per ordered set of instance variables. A
# class whose objects reach 8 shape variations turns new variations into
# hash-backed objects several times their compact size, so pins and types set
# every memoized ivar in #initialize. The examples cover pins and types.
describe Solargraph::Pin::Base do
  let(:code) do
    <<~RUBY
      module Greeting
        # @return [String]
        def greet; 'hi'; end
      end

      # A widget
      # @generic T
      class Widget < Struct
        include Greeting
        extend Enumerable
        LIMIT = 3
        @@count = 0
        $registry = {}

        attr_accessor :size

        # @!method dynamic(arg)
        #   @return [Integer]

        # @param name [String]
        # @param opts [Hash{Symbol => Integer}]
        # @yieldparam [Integer]
        # @return [Array<String>]
        def initialize name, *rest, key: 1, **opts, &block
          @name = name
          list = [name, :sym]
          list.each { |item| item.to_s }
          yield 1 if block
        end

        # @overload build(a)
        #   @param a [Integer]
        #   @return [Widget]
        def self.build(*args)
          new('x')
        end

        alias make greet

        # @!visibility private

        def hidden; end

        private

        def secret
          @name ||= 'x'
        end
      end
    RUBY
  end

  let(:api_map) do
    api_map = Solargraph::ApiMap.new
    api_map.map Solargraph::Source.load_string(code, 'widget.rb')
    api_map
  end

  # Methods mapped from the code above, not loaded from a gem or core cache that
  # an older version may have written
  let(:widget_methods) do
    (api_map.get_methods('Widget') + api_map.get_methods('Widget', scope: :class))
      .select { |pin| pin.location&.filename == 'widget.rb' }
  end

  # Readers that memoize, called in different orders on different pins
  let(:readers) do
    %i[completion_item resolve_completion_item documentation detail signatures parameter_names path return_type
       identity docstring macros macro_names deprecated? probed? proxied? gates link_documentation generics
       generic_defaults context full_context binder maybe_directives? directives signature_help overloads
       method_name desc to_rbs reference_gates type end_position typify_from_signatures nil_type? tag]
  end

  def exercise objects, order
    objects.each do |object|
      order.each do |reader|
        next unless object.respond_to?(reader) && object.method(reader).arity.zero?

        object.public_send(reader)
      rescue StandardError
        nil
      end
    end
  end

  def exercise_with_api_map pins
    pins.each do |pin|
      %i[typify probe].each do |m|
        pin.public_send(m, api_map)
      rescue StandardError
        nil
      end
      pin.rebind(api_map) if pin.is_a?(Solargraph::Pin::Block)
    end
  end

  def too_complex? object
    ObjectSpace.dump(object).include?('"too_complex_shape":true')
  end

  it 'keeps the ivars of every pin as #initialize set them' do
    pins = api_map.source_map('widget.rb').all_pins + widget_methods
    pins += pins.grep(Solargraph::Pin::Method).flat_map { |pin| pin.signatures + pin.parameters }
    pins.uniq!(&:object_id)
    before = {}.compare_by_identity
    pins.each { |pin| before[pin] = pin.instance_variables }

    exercise(pins.each_slice(2).map(&:first), readers)
    exercise(pins.each_slice(2).map(&:last), readers.reverse)
    exercise_with_api_map(pins)

    changed = pins.reject { |pin| before[pin] == pin.instance_variables }
    expect(changed.map { |pin| [pin.class, pin.instance_variables - before[pin]] }).to eq([])
  end

  it 'gives all pins of a class the same ivars in the same order' do
    pins = api_map.source_map('widget.rb').all_pins + widget_methods
    exercise(pins, readers)

    orders = pins.group_by(&:class).transform_values { |list| list.map(&:instance_variables).uniq.size }
    expect(orders.select { |_, count| count > 1 }).to eq({})
  end

  it 'does not give a visibility to pins without one from a @!visibility directive' do
    source_map = Solargraph::SourceMap.load_string(<<~RUBY)
      class Foo
        [1].each { |x| :sym }

        # @!visibility private

        def bar; end
      end
    RUBY
    pins = source_map.all_pins.select { |pin| pin.is_a?(Solargraph::Pin::Block) || pin.is_a?(Solargraph::Pin::Symbol) }

    expect(pins.size).to eq(2)
    expect(pins.map { |pin| pin.instance_variable_defined?(:@visibility) }).to eq([false, false])
  end

  it 'keeps the ivars of types as #initialize set them' do
    types = ['String', 'Array<String>', 'Hash{Symbol => Integer}', 'Array(String, Integer)', '::Class<Foo>',
             '#to_s', 'nil', 'self', 'generic<T>', 'Boolean', 'String, nil'].map { |tag| Solargraph::ComplexType.parse(tag) }
    uniques = types.flat_map(&:items)
    before = {}.compare_by_identity
    (types + uniques).each { |type| before[type] = type.instance_variables }
    type_readers = %i[tag rooted_tag duck_type? nil_type? tuple? namespace substring rooted_substring scope
                      non_literal_name to_rbs desc]

    exercise(types + uniques, type_readers)
    exercise((types + uniques).reverse, type_readers.reverse)

    changed = (types + uniques).reject { |type| before[type] == type.instance_variables }
    expect(changed.map { |type| [type.class, type.instance_variables - before[type]] }).to eq([])
    expect(uniques.map(&:instance_variables).uniq.size).to eq(1)
  end

  it 'loads marshalled pins with the same ivars in the same order' do
    pins = api_map.source_map('widget.rb').all_pins
    exercise(pins, readers)
    pins.each { |pin| pin.detach_nodes! if pin.respond_to?(:detach_nodes!) }
    loaded = Marshal.load(Marshal.dump(pins))

    expect(loaded.map(&:instance_variables)).to eq(pins.map(&:instance_variables))
    expect(loaded.select { |pin| too_complex?(pin) }.map(&:class)).to eq([])
  end

  it 'keeps method pins at a compact size' do
    pins = widget_methods
    exercise(pins, readers)

    # 640 bytes is the largest embedded object slot; hash-backed method pins
    # took 1,200 to 2,000 bytes
    expect(pins.map { |pin| ObjectSpace.memsize_of(pin) }.max).to be <= 640
  end
end
