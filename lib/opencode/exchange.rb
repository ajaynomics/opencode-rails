# frozen_string_literal: true

module Opencode
  # The OpenCode messages produced by a single turn (the array returned
  # by GET /session/:id/message and consumed by Opencode::Turn's
  # recovery + finalization paths).
  #
  # First-class noun rather than a bare array because:
  #
  #   - It owns the "give me the tool-produced artifacts" question, so
  #     callers don't reach into ResponseParser for that. The parser is
  #     about wire-shape extraction; the Exchange is about the domain
  #     concept of "what files came out of this turn."
  #
  #   - It owns the "opencode.apply_patch.artifacts_dropped" event
  #     emission, keeping ResponseParser a pure module (no instrumentation
  #     side effects). Pure functions stay pure. The event flows through
  #     Opencode::Instrumentation, so hosts wire AS::Notifications /
  #     Rails.event / OpenTelemetry / etc. via the adapter.
  class Exchange
    def initialize(messages)
      @messages = Array(messages)
    end

    # Returns Opencode::Artifact values for every file produced by a
    # tool call in this exchange (currently the `write` tool; apply_patch
    # is acknowledged-but-empty in v1.15+, see ResponseParser).
    #
    # `exclude:` filters by destination filename — used by the substrate
    # to keep tool-extracted Artifacts from racing per-message transforms
    # that own the same filenames.
    def tool_artifacts(exclude: [])
      excluded = Set.new(exclude)
      raw = Opencode::ResponseParser.extract_artifacts_from_messages(@messages)
      notify_drops(raw)

      raw.filter_map do |file_data|
        next if excluded.include?(file_data[:filename])

        Artifact.new(
          filename:     file_data[:filename],
          content:      file_data[:content],
          content_type: file_data[:content_type]
        )
      end
    end

    private

    # ResponseParser annotates dropped apply_patch parts on the messages
    # it processes (since v1.15+ wire shape carries no inline post-write
    # content). The notify lives here, not in the parser, so the parser
    # stays a pure function. Operators see one event per assistant
    # message that contained an apply_patch tool call.
    def notify_drops(_)
      @messages.each do |message|
        next unless message.dig(:info, :role) == "assistant"

        parts = message[:parts] || []
        parts.each do |part|
          next unless part[:type] == "tool" && part[:tool] == "apply_patch"
          next unless part.dig(:state, :status) == "completed"

          file_entries = part.dig(:state, :metadata, :files) || []
          eligible = file_entries.reject { |e| e[:type] == "delete" }
          next if eligible.empty?

          Opencode::Instrumentation.instrument("opencode.apply_patch.artifacts_dropped",
            file_count:     eligible.size,
            relative_paths: eligible.filter_map { |e| e[:relativePath] }.first(5),
            message_id:     part[:messageID],
            session_id:     part[:sessionID],
            reason:         "apply_patch v1.15+ metadata does not include post-write file content; " \
                            "extraction requires sandbox-read which is not yet wired into ResponseParser") { }
        end
      end
    end
  end
end
