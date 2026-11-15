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
      open_source = @open_sources[filename]
      return open_source if open_source
      cached = @lru.delete(filename)
      # @sg-ignore Hash#delete returns generic<T>
      @lru[filename] = cached if cached
      cached
    end

    # @param filename [String]
    # @param stamp [Array(Time, Integer)]
    # @return [Source, nil]
    def load filename, stamp
      stat = File.stat(filename)
      return nil unless [stat.mtime, stat.size] == stamp
      code = File.read(filename)
      return nil unless code.bytesize == stamp.last
      source = Source.load_string(code, filename)
      source.node
      source
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
