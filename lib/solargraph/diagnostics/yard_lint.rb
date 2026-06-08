# frozen_string_literal: true

module Solargraph
  module Diagnostics
    # This reporter provides linting through yard-lint.
    #
    class YardLint < Base
      include YardLintHelpers

      # Conversion of yard-lint severity names to LSP constants
      SEVERITIES = {
        'convention' => Severities::INFORMATION,
        'warning' => Severities::WARNING,
        'error' => Severities::ERROR
      }.freeze

      # @param source [Solargraph::Source]
      # @param _api_map [Solargraph::ApiMap]
      # rubocop:disable YARD/CollectionStyle
      # @return [Array<Hash{:range => Hash; :severity => Integer; :source, :code, :message => String}>]
      # rubocop:enable YARD/CollectionStyle
      def diagnose source, _api_map
        @source = source
        return [] unless lintable?(source)

        require_yard_lint(yard_lint_version)
        result = Solargraph::CHDIR_MUTEX.synchronize do
          Yard::Lint.run(path: source.filename, progress: false)
        end
        return [] if result.clean?

        result.offenses.map { |off| offense_to_diagnostic(off) }
      rescue InvalidYardLintVersionError
        raise
      rescue StandardError => e
        raise DiagnosticsError, "Error running yard-lint: #{e.message}"
      end

      private

      # yard-lint reads from disk and cannot accept unsaved buffer contents,
      # so only lint when the source is backed by a file whose contents on
      # disk match the buffer.
      #
      # @param source [Solargraph::Source]
      # @return [Boolean]
      def lintable? source
        filename = source.filename
        return false if filename.nil? || filename.empty?
        return false unless File.file?(filename)

        File.read(filename) == source.code
      end

      # @return [String]
      def yard_lint_version
        args.find { |a| a =~ /version=/ }.to_s.split('=').last
      end

      # Convert a yard-lint offense to an LSP diagnostic
      #
      # rubocop:disable YARD/CollectionStyle
      # @param off [Hash{:name, :message, :location, :severity, :type => String; :line, :location_line => Integer}] Offense received from yard-lint
      # @return [Hash{:range => Hash; :severity => Integer; :source, :code, :message => String}] LSP diagnostic
      # rubocop:enable YARD/CollectionStyle
      def offense_to_diagnostic off
        {
          range: offense_range(off).to_hash,
          severity: SEVERITIES[off[:severity]] || Severities::WARNING,
          source: 'yard-lint',
          code: off[:name],
          message: off[:message]
        }
      end

      # yard-lint reports offenses at line granularity only (no column),
      # so the range spans the entire reported line.
      #
      # @param off [Hash{:line, :location_line => Integer}]
      # @return [Range]
      def offense_range off
        line = (off[:location_line] || off[:line] || 1).to_i - 1
        line = 0 if line.negative?
        line_text = @source.code.lines[line] || ''
        end_col = line_text.chomp.length
        Range.new(Position.new(line, 0), Position.new(line, end_col))
      end
    end
  end
end
