# frozen_string_literal: true

module Opencode
  # The collection of new artifacts attached to an assistant message as
  # a result of one turn. The orchestrator that used to live in
  # Opencode::ArtifactCollector now lives on this collection — instead
  # of a "Collector" verb-class, the collection knows how to populate
  # itself from sources (tool exchange, sandbox) and how to attach.
  #
  # Two-line usage:
  #
  #   Opencode::MessageArtifacts.new(message: m, feature: "chat", transforms: [])
  #     .attach_from(exchange: exchange, sandbox: sandbox)
  #
  # All four phases (tool extract, transform routing, impostor purge,
  # default sandbox attach) live as small named methods. The substrate
  # never special-cases a product — `:feature` is only for error-report
  # context, and `:transforms` (default []) is per-product policy.
  #
  # Idempotent under retry: `Opencode::Artifact#attach_to` already
  # skips when the filename is present on the message, and the
  # tool-extracted phase excludes filenames the transforms own.
  class MessageArtifacts
    MAX_SANDBOX_ARTIFACTS = 20

    # default_attach values:
    #   :all  — every safe sandbox file that no transform claims falls
    #           through to identity attach. Use when the agent's `write`
    #           outputs are final document bytes the host serves back
    #           unchanged.
    #   :none — only transform-claimed files attach; everything else stays
    #           agent-internal. Use when the agent's sandbox is full of
    #           working scratch the user shouldn't see, and only specific
    #           filenames (claimed by transforms) become artifacts.
    def initialize(message:, feature:, transforms: [], default_attach: :all,
                   max_sandbox_files: MAX_SANDBOX_ARTIFACTS)
      @message           = message
      @feature           = feature
      @transforms        = transforms
      @default_attach    = default_attach
      @max_sandbox_files = max_sandbox_files
    end

    # Drains both sources and attaches. Returns self so callers can
    # chain off it if they want to count what landed.
    def attach_from(exchange: nil, sandbox: nil, cutoff: nil, upload_echo: [])
      attach_from_exchange(exchange) if exchange
      attach_from_sandbox(sandbox, cutoff: cutoff, upload_echo: upload_echo) if sandbox
      self
    rescue StandardError => e
      report(e, action: "attach_artifacts")
      self
    end

    private

    attr_reader :message, :feature, :transforms, :max_sandbox_files, :default_attach

    # Tool-produced artifacts (write tool's input content). Skip any
    # filename a transform owns — those land via the sandbox path so the
    # transform's trust pipeline (render + metadata stamp) is the only
    # way the bytes reach the user.
    def attach_from_exchange(exchange)
      exchange.tool_artifacts(exclude: transform_owned_filenames).each do |artifact|
        artifact.attach_to(message)
      end
    rescue StandardError => e
      report(e, action: "attach_from_exchange")
    end

    def attach_from_sandbox(sandbox, cutoff:, upload_echo:)
      return unless sandbox.exists?

      uploaded = Set.new(upload_echo)
      attached = 0

      sandbox.files(after: cutoff).each do |file|
        break if attached >= max_sandbox_files
        next if uploaded.include?(file.basename)

        if (transform = transforms.find { |t| t.applies_to?(file) })
          attached += 1 if apply_transform(transform, file)
        elsif transform_owned_filenames.include?(file.basename)
          # Destination names belong exclusively to their host transform.
          # Agent-authored bytes must never fall through as trusted output.
          next
        elsif default_attach == :all
          # Default identity path: every safe sandbox file that no
          # transform claims attaches as-is. Callers that want the
          # opposite (only transform-claimed files attach) construct
          # MessageArtifacts with default_attach: :none.
          attached += 1 if file.as_artifact.attach_to(message)
        end
      end
    rescue StandardError => e
      report(e, action: "attach_from_sandbox")
    end

    # Returns true if a fresh trusted artifact was attached. Falsy on
    # already-trusted-attached, transform-raised, or duplicate-filename.
    def apply_transform(transform, file)
      if transform.purge_impostors?
        purged = Impostor.for(message: message, transform: transform)
        if purged.any?
          purged.each(&:purge!)
          # ActiveStorage purges the attachment + blob, but `message.artifacts`
          # holds the pre-purge collection in memory. Without resetting,
          # Artifact#already_attached_to? still sees the (just-purged) row
          # and shortcuts the trusted attach below.
          message.artifacts.reset
        end
      end
      return false if trusted_present?(transform)

      artifact = transform.render(file)
      artifact.attach_to(message)
    rescue Transform::Error => e
      report(e, action: "transform_#{transform.class.name.demodulize}")
      false
    end

    def trusted_present?(transform)
      message.artifacts.any? { |a| transform.trusted?(a) }
    end

    def transform_owned_filenames
      transforms.flat_map(&:owned_filenames)
    end

    def report(error, action:)
      Opencode::ErrorReporter.report(error, handled: true, severity: :warning,
        context: { feature: feature, action: action, message_id: message.id })
    end
  end
end
