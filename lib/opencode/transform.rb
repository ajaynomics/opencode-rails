# frozen_string_literal: true

module Opencode
  # A per-product rule that converts an Opencode::SandboxFile into an
  # Opencode::Artifact, owning the trust boundary between "bytes the
  # agent wrote" and "bytes the host signs and attaches."
  #
  # The default substrate path is identity: any sandbox file the
  # allowlist accepts gets attached as-is. This works when the agent
  # writes the final document bytes itself and the host just serves
  # them back unchanged.
  #
  # Subclass Transform when the contract is structurally different:
  # the agent writes raw data (e.g. JSON), and the **host** must
  # render that data into trusted output (e.g. HTML) before attaching.
  # The split matters when the resulting bytes get served inline from
  # your app origin — an agent-written filename can't be permitted as
  # stored-XSS, so a Transform draws the trust boundary.
  #
  # Subclass hooks (override these — none have a generic default
  # that's safe to inherit):
  #
  #   source_filename       — basename in the sandbox the transform
  #                           reads from
  #   destination_filename  — filename of the Artifact the transform
  #                           returns from #render
  #   render(sandbox_file)  — return an Artifact carrying the rendered
  #                           bytes + trust metadata. Raise
  #                           Opencode::Transform::Error to abort just
  #                           this file (substrate logs + skips).
  #   trusted?(attachment)  — true if the attachment was produced by
  #                           this transform (used by Impostor.for and
  #                           by view code that decides inline-render
  #                           vs download). Default: false; subclasses
  #                           must verify host-authored metadata.
  #   purge_impostors?      — if true, before attaching the substrate
  #                           deletes any existing attachment whose
  #                           filename matches destination_filename
  #                           but fails trusted?. Default: false.
  #
  # `applies_to?(sandbox_file)` is the routing predicate the substrate
  # uses to decide whether to send this file through this transform.
  # Default is exact match against source_filename; override for
  # multi-file or glob-style ownership.
  class Transform
    Error = Class.new(StandardError)

    def destination_filename
      raise NotImplementedError, "#{self.class.name} must implement #destination_filename"
    end

    def source_filename
      raise NotImplementedError, "#{self.class.name} must implement #source_filename"
    end

    def applies_to?(sandbox_file)
      sandbox_file.basename == source_filename
    end

    def render(_sandbox_file)
      raise NotImplementedError, "#{self.class.name} must implement #render"
    end

    def trusted?(_attachment)
      false
    end

    def purge_impostors?
      false
    end

    # Names this transform owns end-to-end. The substrate uses this to
    # keep its tool-extracted phase from racing the transform — the
    # agent's raw payload (source_filename) and the rendered output
    # (destination_filename) are both off-limits to the default attach
    # path so the transform owns the slot.
    def owned_filenames
      [ source_filename, destination_filename ]
    end
  end
end
