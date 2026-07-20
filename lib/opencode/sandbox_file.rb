# frozen_string_literal: true

require "pathname"

module Opencode
  # One file living inside an Opencode::Sandbox.
  #
  # Carries the safety predicate inline (#safe?) so the orchestrator
  # doesn't have to know what "safe" means — symlink, realpath inside
  # the sandbox, size cap. Carries the default identity conversion to
  # Artifact (#as_artifact) so non-transform code can attach a sandbox
  # file as-is without re-implementing the marcel + StringIO ceremony.
  #
  # mtime-cutoff freshness lives on Opencode::Sandbox#files(after:),
  # not here — the file doesn't know which turn opened "after." That's
  # a property of the scan, not a property of the file.
  class SandboxFile
    UnsafeFileError = Class.new(Opencode::Error)

    attr_reader :path, :sandbox_prefix

    def initialize(path:, sandbox_prefix:, max_bytes:)
      @path           = path
      @sandbox_prefix = sandbox_prefix
      @max_bytes      = max_bytes
    end

    def basename
      File.basename(path)
    end

    def size
      File.size(path)
    end

    def mtime
      File.mtime(path)
    end

    def content
      with_safe_file do |file|
        content = file.read(@max_bytes + 1) || "".b
        if content.bytesize > @max_bytes
          raise UnsafeFileError, "Sandbox file exceeds size limit while reading: #{basename}"
        end
        content
      end
    end

    def content_type
      Marcel::MimeType.for(name: basename)
    end

    # Defense-in-depth on individual file paths the scan yielded:
    #
    #   - Reject symlinks (no follow-the-link escape).
    #   - The resolved realpath of the path must lie inside the sandbox
    #     with a separator-terminated prefix so /sandbox-1 doesn't false-
    #     positive on /sandbox-10/foo.
    #   - Reject anything over the size cap (default
    #     Opencode::ResponseParser::MAX_ARTIFACT_SIZE = 10 MB).
    #
    # Revalidates the opened file descriptor so a path swap between the
    # sandbox scan and the read cannot redirect content outside the sandbox.
    def safe?
      with_safe_file { true }
    rescue UnsafeFileError
      false
    end

    # Identity conversion: this sandbox file → an Artifact carrying the
    # file's own bytes. Used by the substrate's default (non-transform)
    # path, where the agent writes document bytes directly to the
    # sandbox and the host serves them back unchanged.
    def as_artifact
      Artifact.new(
        filename:     basename,
        content:      content,
        content_type: content_type
      )
    end

    private

    def with_safe_file
      before = File.lstat(path)
      raise UnsafeFileError, "Unsafe sandbox file: #{basename}" unless before.file? && !before.symlink?

      resolved = Pathname.new(path).realpath.to_s
      unless resolved.start_with?(sandbox_prefix)
        raise UnsafeFileError, "Sandbox file escapes its root: #{basename}"
      end

      File.open(path, "rb") do |file|
        opened = file.stat
        unless opened.file? && opened.dev == before.dev && opened.ino == before.ino
          raise UnsafeFileError, "Sandbox file changed while opening: #{basename}"
        end
        if opened.size > @max_bytes
          raise UnsafeFileError, "Sandbox file exceeds size limit: #{basename}"
        end

        yield file
      end
    rescue Errno::ENOENT, Errno::ELOOP => e
      raise UnsafeFileError, "Unsafe sandbox file #{basename}: #{e.message}"
    end
  end
end
