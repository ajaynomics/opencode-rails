# frozen_string_literal: true

module Opencode
  # The per-user (or per-trip) sandbox directory the agent's container
  # writes into. A first-class noun rather than a path-string with
  # primitives sprinkled around the codebase: the Sandbox knows its
  # own path, knows how to walk itself, knows what "fresh enough" means
  # for a given turn, and yields SandboxFile values that carry their
  # own safety predicate.
  #
  # Used by Opencode::MessageArtifacts. Construct one with the path,
  # then ask it for `files(after:)` where `after` is the user message's
  # created_at time (minus CUTOFF_SLACK). Files older than the cutoff
  # are stale leftovers from a previous turn — never attached.
  class Sandbox
    # Two-second slack absorbs clock skew between the Rails app and the
    # per-user OpenCode container. Without it, a file written by the
    # container in the same wall-clock second as the user message could
    # be (mtime < created_at) and get rejected.
    CUTOFF_SLACK = 2.seconds

    attr_reader :path

    def initialize(path:, max_file_bytes: Opencode::ResponseParser::MAX_ARTIFACT_SIZE)
      @path           = path
      @max_file_bytes = max_file_bytes
    end

    def exists?
      path.present? && Dir.exist?(path)
    end

    # Yields SandboxFile values for every file in the sandbox that
    # passes its own #safe? predicate AND was modified after the cutoff.
    # When `after:` is nil (callers without a user_message handle —
    # e.g. finalize paths that scan the whole sandbox), no mtime filter
    # is applied — only safety + filetype.
    def files(after: nil)
      return enum_for(:files, after: after) unless block_given?
      return unless exists?

      cutoff = after && (after.to_time - CUTOFF_SLACK)

      Dir.glob(File.join(path, "*")).each do |entry|
        next unless File.file?(entry)
        next if cutoff && File.mtime(entry) < cutoff

        file = SandboxFile.new(
          path:           entry,
          sandbox_prefix: prefix,
          max_bytes:      @max_file_bytes
        )
        next unless file.safe?

        yield file
      end
    end

    def file(basename, after: nil)
      files(after: after).find { |f| f.basename == basename }
    end

    private

    # Separator-terminated prefix so /sandbox-1 doesn't false-positive
    # on /sandbox-10/foo when SandboxFile checks realpath containment.
    def prefix
      @prefix ||= File.join(path, "")
    end
  end
end
