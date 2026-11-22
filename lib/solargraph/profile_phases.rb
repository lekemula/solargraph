# frozen_string_literal: true

module Solargraph
  # Drives a language server host through the phases that `solargraph profile`
  # measures, so that each phase holds only its own work: mapping the
  # workspace, the first catalog, and definition requests.
  #
  # The host maps a library on a background thread, and Library#next_map starts
  # the first catalog on that thread as soon as the last file is mapped. To keep
  # that catalog out of the mapping phase, the library's mapping thread is held
  # at its first call to Library#catalog until #catalog releases it.
  class ProfilePhases
    # @param host [LanguageServer::Host]
    def initialize host
      @host = host
      # @type [Array<Thread>]
      @mapping = []
      # @type [Array<Library>]
      @unmapped = []
      @reached = Thread::Queue.new
      @release = Thread::Queue.new
      # Loads the message classes now, as a running server has them loaded
      # before its first request.
      @definition_class = LanguageServer::Message.select('textDocument/definition')
    end

    # Prepare a library for the directory and return once its files are
    # mapped. The first catalog has not started yet.
    #
    # @param directory [String]
    # @return [void]
    def map directory
      hold_first_catalog
      @host.prepare(directory)
      @mapping.each do |thread|
        nil until @reached.pop(timeout: 0.05) || !thread.alive?
      end
    end

    # Let the held mapping threads run the first catalog and return once every
    # library is synchronized.
    #
    # @return [void]
    def catalog
      @mapping.each do |thread|
        @release.push(true)
        thread.join
      end
      @unmapped.each do |library|
        library.catalog
        library.get_path_pins('')
      end
    end

    # @param uri [String]
    # @param line [Integer] zero-based
    # @param column [Integer] zero-based
    # @return [Array<Hash>, Hash, nil] the response's result
    def definition uri, line, column
      message = @definition_class.new(
        @host, {
          'params' => {
            'textDocument' => { 'uri' => uri },
            'position' => { 'line' => line, 'character' => column }
          }
        }
      )
      message.process
      message.result
    end

    private

    # @return [void]
    def hold_first_catalog
      hold = method(:hold_catalog_of)
      track = method(:track)
      library_map = @host.method(:library_map)
      @host.define_singleton_method(:library_map) do |library|
        hold.call(library)
        thread = library_map.call(library)
        track.call(library, thread)
        thread
      end
    end

    # @param library [Library]
    # @return [void]
    def hold_catalog_of library
      # Host#library_map starts no mapping thread for a mapped library
      return if library.mapped?

      reached = @reached
      release = @release
      held = false
      catalog = library.method(:catalog)
      library.define_singleton_method(:catalog) do
        unless held
          held = true
          reached.push(true)
          release.pop
        end
        catalog.call
      end
    end

    # @param library [Library]
    # @param thread [Thread, nil]
    # @return [void]
    def track library, thread
      if thread
        @mapping.push thread
      else
        @unmapped.push library
      end
    end
  end
end
