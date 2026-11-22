# frozen_string_literal: true

require 'yard'
require 'solargraph/yard_tags'

module Solargraph
  # An index of Pins and other ApiMap-related data for a single Source
  # that can be queried.
  #
  class SourceMap
    autoload :Mapper,        'solargraph/source_map/mapper'
    autoload :Clip,          'solargraph/source_map/clip'
    autoload :Completion,    'solargraph/source_map/completion'
    autoload :Data,          'solargraph/source_map/data'
    autoload :Call,          'solargraph/source_map/call'

    # The mapped source. After #evict! it is parsed again from disk through
    # the SourceCache.
    #
    # @raise [FileNotFoundError] if the evicted file changed or cannot be read
    # @return [Source]
    def source
      resident = @source || @scanned_source
      return resident if resident
      name = @filename
      loaded = SourceCache.instance.fetch(name) if name
      return loaded if loaded
      raise FileNotFoundError, "Source of #{name} is not available"
    end

    # @return [Array<Pin::Base>]
    def pins
      data.pins
    end

    # @return [Array<Pin::Base>]
    def all_pins
      pins + convention_pins
    end

    # @return [Array<Pin::LocalVariable>]
    def locals
      data.locals
    end

    # @param source [Source]
    def initialize source
      @source = source
      @filename = source.filename
      # @type [Array<Pin::Base>, nil]
      @convention_pins = nil

      conventions_environ.merge Convention.for_local(self) unless filename.nil?
      # FIXME: unmemoizing the document_symbols in case it was called and memoized from any of conventions above
      # this is to ensure that the convention_pins from all conventions are used in the document_symbols.
      # solargraph-rails is known to use this method to get the document symbols. It should probably be removed.
      @document_symbols = nil
      self.convention_pins = conventions_environ.pins
      # @type [Hash{Class<Pin::Base> => Array<Pin::Base>}]
      @pin_select_cache = {}
    end

    # @generic T
    # @param klass [Class<generic<T>>]
    #
    # @return [Array<generic<T>>]
    def pins_by_class klass
      @pin_select_cache[klass] ||= pin_class_hash.select { |key, _| key <= klass }.values.flatten
    end

    # @return [String, nil]
    attr_reader :filename

    # @return [String]
    def code
      source.code
    end

    # @return [Array<Pin::Reference::Require>]
    def requires
      pins_by_class(Pin::Reference::Require)
    end

    def calls *method_names
      return [] unless calls_any?(method_names.map(&:to_s))
      symbolized = method_names.map(&:to_sym)
      node_map.find_by_type(:send).select { |node| node.children[0].nil? && symbolized.include?(node.children[1].to_sym) }
              .map { |node| Call.new(self, Parser.chain(node), locate_namespace_pin(node.loc.line, node.loc.column)) }
    rescue FileNotFoundError
      []
    end

    def node_map
      return @node_map if @node_map
      # @sg-ignore Need to add nil check here
      map = Source::NodeMap.new(source.node)
      @node_map = map unless evicted?
      map
    end

    # True if the source's text and syntax tree were dropped after mapping.
    def evicted?
      @source.nil?
    end

    # Drop the source's text and syntax tree once the pins are generated. Pins
    # keep NodeRefs and parse their nodes again on demand through the
    # SourceCache, which gets the file's state on disk now.
    #
    # @return [void]
    def evict!
      name = filename
      return if evicted? || name.nil?
      call_names
      SourceCache.instance.register name
      (all_pins + locals).each { |pin| pin.detach_nodes!(reload_from: name) }
      document_symbols
      @source = nil
      @node_map = nil
      @method_call_nodes = nil
      @macro_method_names = nil
      @macro_method_candidates = nil
    end

    # Names of the methods the file calls without a receiver. They are kept
    # after eviction, so a workspace-wide scan for calls parses only the
    # files that make one.
    #
    # @return [Array<String>]
    def call_names
      @call_names ||= begin
        root = source.node
        root ? collect_call_names(root, Set.new).to_a.freeze : []
      end
    rescue FileNotFoundError
      []
    end

    # True if the file calls one of the methods without a receiver.
    #
    # @param names [Enumerable<String>]
    def calls_any? names
      call_names.any? { |name| names.include?(name) }
    end

    # Run a workspace-wide scan on the file's source. The source of an
    # evicted file is read past the SourceCache's LRU, serves #source while
    # the block runs and is dropped afterwards.
    #
    # @generic T
    # @yieldreturn [generic<T>]
    # @return [generic<T>, nil] nil if the evicted file changed on disk
    def scan_source
      return yield if @source || @scanned_source
      name = filename
      return nil if name.nil?
      loaded = SourceCache.instance.read(name)
      return nil unless loaded
      begin
        @scanned_source = loaded
        yield
      ensure
        @scanned_source = nil
      end
    end

    # @return [Environ]
    def conventions_environ
      @conventions_environ ||= Environ.new
    end

    # all pins except Solargraph::Pin::Reference::Reference
    #
    # @return [Array<Pin::Base>]
    def document_symbols
      @document_symbols ||= (pins + convention_pins).select do |pin|
        pin.path && !pin.path.empty?
      end
    end

    # @param query [String]
    # @return [Array<Pin::Base>]
    def query_symbols query
      Pin::Search.new(document_symbols, query).results
    end

    # @param position [Position, Array(Integer, Integer)]
    # @return [Source::Cursor]
    def cursor_at position
      Source::Cursor.new(source, position)
    end

    # @param path [String]
    # @return [Pin::Base]
    def first_pin path
      pins.select { |p| p.path == path }.first
    end

    # @param location [Solargraph::Location]
    # @return [Array<Solargraph::Pin::Base>]
    def locate_pins location
      # return nil unless location.start_with?("#{filename}:")
      (pins + locals).select { |pin| pin.location == location }
    end

    # @param line [Integer]
    # @param character [Integer]
    # @return [Pin::Method,Pin::Namespace]
    def locate_named_path_pin line, character
      _locate_pin line, character, Pin::Namespace, Pin::Method
    end

    def locate_namespace_pin line, character
      _locate_pin line, character, Pin::Namespace, Pin::Singleton
    end

    # @param line [Integer]
    # @param character [Integer]
    # @return [Pin::Closure]
    def locate_closure_pin line, character
      _locate_pin line, character, Pin::Closure
    end

    # @deprecated Please use locate_closure_pin instead
    alias locate_block_pin locate_closure_pin

    # @param name [String]
    # @return [Array<Location>]
    def references name
      source.references name
    end

    # @param location [Location]
    # @return [Array<Pin::LocalVariable>]
    def locals_at location
      return [] if location.filename != filename
      closure = locate_closure_pin(location.range.start.line, location.range.start.character)
      locals.select { |pin| pin.visible_at?(closure, location) }
    end

    # @return [Array<Parser::AST::Node>]
    def method_call_nodes
      return @method_call_nodes if @method_call_nodes
      # @sg-ignore node expected Parser::AST::Node, received Parser::AST::Node, nil
      nodes = Solargraph::Parser::ParserGem::NodeMethods.call_nodes_from(source.node)
      @method_call_nodes = nodes unless evicted?
      nodes
    rescue FileNotFoundError
      []
    end

    # @sg-ignore flow sensitive typing needs to handle && in modifiers
    # @param macro_method_names [Enumerable<String>]
    # @return [Array<Parser::AST::Node>]
    def macro_method_candidates macro_method_names
      cached = @macro_method_candidates
      return cached if cached && @macro_method_names == macro_method_names
      candidates = method_call_nodes.select { |node| macro_method_names.include?(node.children[1].to_s) }
      return candidates if evicted?
      @macro_method_names = macro_method_names
      @macro_method_candidates = candidates
    end

    class << self
      # @param filename [String]
      # @return [SourceMap]
      def load filename
        source = Solargraph::Source.load(filename)
        SourceMap.map(source)
      end

      # @param code [String]
      # @param filename [String, nil]
      # @return [SourceMap]
      def load_string code, filename = nil
        source = Solargraph::Source.load_string(code, filename)
        SourceMap.map(source)
      end

      # @deprecated
      # @param source [Source]
      # @return [SourceMap]
      def map source
        new(source)
      end
    end

    # @return [Array<Pin::Base>]
    def convention_pins
      @convention_pins || []
    end

    private

    # @param node [::Parser::AST::Node]
    # @param names [Set<String>]
    # @return [Set<String>]
    def collect_call_names node, names
      # @sg-ignore A send node's second child is the method name Symbol
      names.add node.children[1].name if node.type == :send && node.children[0].nil?
      # @sg-ignore Node children are untyped
      node.children.each { |child| collect_call_names(child, names) if child.is_a?(::Parser::AST::Node) }
      names
    end

    # @return [Hash{Class, Pin::Base => Array<Pin::Base>}]
    def pin_class_hash
      # @todo Need to support generic resolution in classify and transform_values
      @pin_class_hash ||= pins.to_set.classify(&:class).transform_values(&:to_a)
    end

    # @return [Data]
    def data
      @data ||= Data.new(source)
    end

    # @param pins [Array<Pin::Base>]
    # @return [Array<Pin::Base>]
    def convention_pins= pins
      # unmemoizing the document_symbols in case it was called from any of conventions
      @document_symbols = nil
      @convention_pins = pins
    end

    # @generic T
    # @param line [Integer]
    # @param character [Integer]
    # @param klasses [Array<Class<generic<T>>>]
    # @return [generic<T>, nil]
    # @sg-ignore Need better generic inference here
    def _locate_pin line, character, *klasses
      position = Position.new(line, character)
      found = nil
      pins.each do |pin|
        # A bodyless method pin covers its declaring statement's range but isn't a closure.
        next if pin.is_a?(Pin::Method) && !pin.body?
        found = pin if (klasses.empty? || klasses.any? do |kls|
          pin.is_a?(kls)
          # @sg-ignore Need to add nil check here
        end) && pin.location.range.contain?(position)
        # @sg-ignore Need to add nil check here
        break if pin.location.range.start.line > line
      end
      # Assuming the root pin is always valid
      found || pins.first
    end
  end
end
