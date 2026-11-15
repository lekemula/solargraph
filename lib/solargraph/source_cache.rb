# frozen_string_literal: true

require 'set'

module Solargraph
  # Parsed sources of workspace files whose text and syntax tree were evicted
  # after mapping. Pins of an evicted file hold NodeRefs, and a lookup parses
  # the file from disk again on a miss.
  #
  # A file is registered with the modification time and size it had when it
  # was mapped. A file that no longer matches is not loaded: its lookups
  # return nil and the file is reported stale until its library maps it again.
  #
  # Sources of open files are kept apart from the LRU and never evicted from
  # the cache while open.
  #
  class SourceCache
    DEFAULT_SIZE = 200

    # @return [Integer]
    attr_reader :size

    class << self
      # @return [SourceCache]
      def instance
        @instance ||= new
      end

      # @return [void]
      def reset!
        @instance = nil
      end
    end

    # @param size [Integer] How many sources of files that are not open to keep
    def initialize size = DEFAULT_SIZE
      @size = size
      # @type [Hash{String => Source}] least recently used first
      @lru = {}
      # @type [Hash{String => Source}]
      @open_sources = {}
      # @type [Set<String>]
      @open = Set.new
      # @type [Hash{String => Array(Time, Integer)}]
      @stamps = {}
      # @type [Set<String>]
      @stale = Set.new
      # @type [Hash{String => Source}] sources of a scan that bypasses the LRU
      @lent = {}
      @mutex = Mutex.new
    end

    # @param value [Integer]
    # @return [void]
    def size= value
      @mutex.synchronize do
        @size = value
        @lru.shift while @lru.length > @size
      end
    end

    # Record the state of a file on disk so it can be reloaded later.
    #
    # @param filename [String]
    # @return [void]
    def register filename
      stat = File.stat(filename)
      @mutex.synchronize do
        @stamps[filename] = [stat.mtime, stat.size]
        @stale.delete filename
        @lru.delete filename
        @open_sources.delete filename
      end
    rescue SystemCallError
      forget filename
    end

    # @param filename [String]
    # @return [void]
    def forget filename
      @mutex.synchronize do
        @stamps.delete filename
        @stale.delete filename
        @lru.delete filename
        @open_sources.delete filename
      end
    end

    # @param filename [String]
    def registered? filename
      @mutex.synchronize { @stamps.key?(filename) }
    end

    # @param filename [String]
    # @return [void]
    def open filename
      @mutex.synchronize do
        @open.add filename
        source = @lru.delete(filename)
        # @sg-ignore Hash#delete returns generic<T>
        @open_sources[filename] = source if source
      end
    end

    # @param filename [String]
    # @return [void]
    def close filename
      @mutex.synchronize do
        @open.delete filename
        @open_sources.delete filename
      end
    end

    # @param filename [String]
    # @return [Source, nil] nil if the file is not registered, changed since
    #   it was registered, or cannot be read
    def fetch filename
      cached = @mutex.synchronize { lookup(filename) }
      return cached if cached
      stamp = @mutex.synchronize { @stamps[filename] unless @stale.include?(filename) }
      return nil if stamp.nil?
      source = load(filename, stamp)
      return stale!(filename) if source.nil?
      insert filename, source
    end

    # A cached source, without marking it as recently used.
    #
    # @param filename [String]
    # @return [Source, nil]
    def peek filename
      @mutex.synchronize { @lent[filename] || @open_sources[filename] || @lru[filename] }
    end

    # The text of a registered file on disk, read without parsing it and
    # without caching anything.
    #
    # @param filename [String]
    # @return [String, nil] nil under the same conditions as #fetch
    def text filename
      stamp = @mutex.synchronize { @stamps[filename] unless @stale.include?(filename) }
      return nil if stamp.nil?
      read_text(filename, stamp) || stale!(filename)
    end

    # Make a source available to node lookups while the block runs, without
    # adding it to the LRU, so a scan of many files does not flush the
    # sources of open files and of inference.
    #
    # @generic T
    # @param source [Source]
    # @yieldreturn [generic<T>]
    # @return [generic<T>]
    def lend source
      name = source.filename
      return yield if name.nil?
      @mutex.synchronize { @lent[name] = source }
      begin
        yield
      ensure
        @mutex.synchronize { @lent.delete name }
      end
    end

    # The source of a registered file for a workspace-wide scan: the cached
    # copy if there is one, otherwise parsed from disk without entering the
    # cache, so a scan does not push out the sources inference needs.
    #
    # @param filename [String]
    # @return [Source, nil] nil if the file is not registered, changed since
    #   it was registered, or cannot be read
    def read filename
      stamp = @mutex.synchronize do
        cached = @lent[filename] || @open_sources[filename] || @lru[filename]
        return cached if cached
        @stamps[filename] unless @stale.include?(filename)
      end
      return nil if stamp.nil?
      load(filename, stamp) || stale!(filename)
    end

    # @param ref [NodeRef]
    # @return [::Parser::AST::Node, nil]
    def node ref
      ref.find_in(fetch(ref.filename)&.node)
    end

    # Remove and return the stale files that match the block.
    #
    # @yieldparam filename [String]
    # @yieldreturn [Boolean]
    # @return [Array<String>]
    def take_stale &block
      @mutex.synchronize do
        taken = @stale.select(&block)
        @stale.subtract taken
        taken
      end
    end

    # @return [Array<String>] filenames in the LRU, least recently used first
    def cached_filenames
      @mutex.synchronize { @lru.keys }
    end

    private

    # @sg-ignore Hash#delete returns generic<T>
    # @param filename [String]
    # @return [Source, nil]
    def lookup filename
      held = @lent[filename] || @open_sources[filename]
      return held if held
      cached = @lru.delete(filename)
      # @sg-ignore Hash#delete returns generic<T>
      @lru[filename] = cached if cached
      cached
    end

    # @param filename [String]
    # @param stamp [Array(Time, Integer)]
    # @return [Source, nil]
    def load filename, stamp
      code = read_text(filename, stamp)
      return nil if code.nil?
      source = Source.load_string(code, filename)
      source.node
      source
    end

    # @param filename [String]
    # @param stamp [Array(Time, Integer)]
    # @return [String, nil]
    def read_text filename, stamp
      stat = File.stat(filename)
      return nil unless [stat.mtime, stat.size] == stamp
      code = File.read(filename)
      return nil unless code.bytesize == stamp.last
      code
    rescue SystemCallError
      nil
    end

    # @param filename [String]
    # @return [nil]
    def stale! filename
      @mutex.synchronize { @stale.add filename if @stamps.key?(filename) }
      nil
    end

    # @param filename [String]
    # @param source [Source]
    # @return [Source]
    def insert filename, source
      @mutex.synchronize do
        return source unless @stamps.key?(filename)
        if @open.include?(filename)
          @open_sources[filename] ||= source
          next @open_sources[filename]
        end
        @lru.delete filename
        @lru[filename] = source
        @lru.shift while @lru.length > @size
        source
      end
    end
  end
end
