# frozen_string_literal: true

module Solargraph
  # Frozen empty collections for pins and types that have nothing to store.
  # Holders share them instead of owning an empty Array or Hash each, and a
  # Marshal round-trip (the gem pin cache) restores the shared frozen
  # instance instead of one unfrozen copy per file.
  #
  # Code that adds to a collection that may be one of these must replace it
  # with a fresh one first.
  module Empty
    # The class of {Empty::ARRAY}.
    class EmptyArray < Array
      # @return [Array]
      def dup
        []
      end

      # @param _level [Integer]
      # @return [String]
      def _dump _level
        empty? ? '' : Marshal.dump(to_a)
      end

      # @param data [String]
      # @return [Array]
      def self._load data
        return ARRAY if data.empty?

        Array(Marshal.load(data)) # rubocop:disable Security/MarshalLoad
      end
    end

    # The class of {Empty::HASH}.
    class EmptyHash < Hash
      # @return [Hash]
      def dup
        {}
      end

      # @param _level [Integer]
      # @return [String]
      def _dump _level
        empty? ? '' : Marshal.dump(to_h)
      end

      # @param data [String]
      # @return [Hash]
      def self._load data
        return HASH if data.empty?

        Hash(Marshal.load(data)) # rubocop:disable Security/MarshalLoad
      end
    end

    ARRAY = EmptyArray.new.freeze
    HASH = EmptyHash.new.freeze

    # @generic T
    # @param array [::Array<generic<T>>]
    # @return [::Array<generic<T>>] {ARRAY} if the array is empty, else the array
    def self.share_array array
      array.empty? ? ARRAY : array
    end

    # @generic K
    # @generic V
    # @param hash [::Hash<generic<K>, generic<V>>]
    # @return [::Hash<generic<K>, generic<V>>] {HASH} if the hash is empty, else the hash
    def self.share_hash hash
      hash.empty? ? HASH : hash
    end
  end
end
