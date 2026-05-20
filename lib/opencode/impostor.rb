# frozen_string_literal: true

module Opencode
  # An ActiveStorage::Attachment on an assistant message that uses a
  # trusted Transform's destination filename but fails the transform's
  # `#trusted?` predicate. In plain English: a same-named attachment
  # that wasn't produced by the host-trusted renderer pipeline.
  #
  # Where impostors come from:
  #
  #   1. A previous job retry attached the destination filename via the
  #      tool-extracted path (the agent wrote a file with that name and
  #      it landed before the trusted render did).
  #   2. A pre-substrate code path persisted an agent-authored HTML file
  #      with the destination filename (the historical AIGL exploit
  #      surface that motivated the trust boundary in the first place).
  #   3. A previous transform version stamped different metadata and the
  #      trust check now correctly rejects it.
  #
  # The Impostor knows how to remove itself. The orchestrator just asks
  # "are there impostors of this transform on this message?" and tells
  # each one to `purge!`. Purging is a verb that belongs to the
  # impostor — it's the noun whose state the purge mutates.
  class Impostor
    # Finds impostors of `transform` on `message` — attachments whose
    # filename matches the transform's destination but whose contents
    # fail the transform's trust predicate.
    def self.for(message:, transform:)
      target = transform.destination_filename
      message.artifacts
        .select { |a| a.filename.to_s == target }
        .reject { |a| transform.trusted?(a) }
        .map    { |a| new(attachment: a) }
    end

    def initialize(attachment:)
      @attachment = attachment
    end

    def purge!
      @attachment.purge
    end

    def filename
      @attachment.filename.to_s
    end
  end
end
