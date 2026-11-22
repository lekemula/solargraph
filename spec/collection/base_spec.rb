# frozen_string_literal: true

describe Solargraph::Collection::Base do
  let(:pin) { Solargraph::Pin::Namespace.new(name: 'Example', type: :class) }

  let(:klass) do
    Class.new(described_class) do
      attr_accessor :pins

      def cache_file
        File.join Solargraph::CacheDir.base_dir, 'example.ser'
      end
    end
  end

  let(:base) { klass.new }

  # Collection::Base memoizes in Collection.mem_cache, so the file has to be
  # the only source left for the load below to be proving anything.
  before { Solargraph::Collection.clear_mem_cache }

  it 'saves caches' do
    base.pins = [pin]
    base.load
    expect(File).to be_file(base.cache_file)
  end

  it 'loads from caches' do
    base.pins = []
    cache = base.load
    expect(cache).to eq([pin])
  end

  describe 'strings loaded from caches' do
    let(:klass) do
      Class.new(described_class) do
        attr_accessor :pins

        def cache_file
          File.join Solargraph::CacheDir.base_dir, 'interned.ser'
        end
      end
    end
    let(:methods) do
      2.times.map { Solargraph::Pin::Method.new(name: +'run', closure: pin, comments: +'Runs it.') }
    end
    let(:loaded) do
      methods.each(&:docstring)
      base.pins = methods
      base.load
      Solargraph::Collection.clear_mem_cache
      base.load
    end

    after { FileUtils.rm_f base.cache_file }

    it 'shares one frozen copy of equal strings' do
      expect(loaded.map(&:name)).to all(be_frozen)
      expect(loaded[0].name).to equal(loaded[1].name)
    end

    it 'leaves docstrings unfrozen' do
      docstring = loaded[0].instance_variable_get(:@docstring)
      expect(docstring).to be_a(YARD::Docstring)
      expect(docstring).not_to be_frozen
    end
  end

  it 'deletes caches' do
    klass.uncache
    expect(File).not_to be_file(base.cache_file)
  end

  it 'forgets pins combined from the cache when it deletes it' do
    Solargraph::Collection.mem_cache["#{base.cache_file}|signatures"] = [pin]
    klass.uncache
    expect(Solargraph::Collection.mem_cache).to be_empty
  end
end
