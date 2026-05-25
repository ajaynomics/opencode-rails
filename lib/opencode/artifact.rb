# frozen_string_literal: true

module Opencode
  # A file the host wants to attach to an assistant message: filename,
  # content bytes, MIME type, and an optional trust-metadata hash.
  #
  # Artifacts come from two places in the substrate:
  #
  #   - Opencode::Exchange.tool_artifacts  — content lives inside a tool
  #     call's input/metadata (write tool).
  #   - Opencode::SandboxFile#as_artifact — identity conversion of a
  #     sandbox-resident file (the default identity path).
  #
  # Transforms also return Artifacts — e.g. a host-rendered HTML
  # artifact carrying a trust-metadata stamp.
  #
  # An Artifact knows how to attach itself to a message, idempotently:
  # it consults `message.artifacts` to skip if its filename is already
  # there. The attaching verb belongs to the Artifact (the noun whose
  # state the verb consults), not to a separate Attacher class.
  class Artifact
    attr_reader :filename, :content, :content_type, :metadata

    def initialize(filename:, content:, content_type:, metadata: {})
      @filename     = filename
      @content      = content
      @content_type = content_type
      @metadata     = metadata
    end

    # Idempotent attach. Returns true if newly attached, false if the
    # filename was already present on the message (so callers can count
    # what they actually persisted vs what was already there).
    def attach_to(message)
      return false if already_attached_to?(message)

      message.artifacts.attach(
        io:           StringIO.new(content),
        filename:     filename,
        content_type: content_type,
        metadata:     metadata
      )
      true
    end

    def already_attached_to?(message)
      message.artifacts.any? { |a| a.filename.to_s == filename }
    end

    def ==(other)
      other.is_a?(Artifact) &&
        other.filename     == filename &&
        other.content      == content &&
        other.content_type == content_type &&
        other.metadata     == metadata
    end
    alias_method :eql?, :==

    def hash
      [ filename, content, content_type, metadata ].hash
    end
  end
end
