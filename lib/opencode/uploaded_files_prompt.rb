# frozen_string_literal: true

module Opencode
  # The prompt body to send to an OpenCode agent when the user attached
  # files: the user's text plus an instruction block naming each file by
  # its sandboxed filename so the agent can read it with the `read` tool.
  #
  # Two outputs, both explicit:
  #
  #   text                  — the prompt body to pass to send_message_async
  #   sandbox_file_names    — map of sandbox_name => original filename,
  #                           used by ReplyStream to show the user a
  #                           recognizable name when the agent reads the
  #                           file back.
  #
  # Previously this work lived in `Opencode::SandboxFiles`, an ActiveSupport
  # concern that mutated a hidden `@sandbox_file_names` instance variable on
  # the including job. ReplyStream then read that ivar back through a
  # closure. State across class boundaries via shared mutable ivars is the
  # kind of Sandi-smelly action-at-a-distance that breaks the moment
  # someone forgets the contract. This value object replaces that with two
  # named return values.
  #
  # Side effect, unchanged from the concern: file bytes are copied from
  # ActiveStorage into the per-user OpenCode sandbox directory so the
  # agent can read them with the `read` tool. The copy is path-escape
  # guarded (the cleanpath of the destination must start with the
  # sandbox dir prefix, no symlink trickery).
  class UploadedFilesPrompt
    attr_reader :text, :sandbox_file_names

    def initialize(user_message:, sandbox_path:, sandbox_name_for:)
      @user_message = user_message
      @sandbox_path = sandbox_path
      @sandbox_name_for = sandbox_name_for
      @sandbox_file_names = {}
      @text = build_text
    end

    private

    def build_text
      raw = @user_message.content.to_s
      return raw unless @user_message.files.attached?

      file_instructions = @user_message.files.map do |file|
        sandbox_file = copy_to_sandbox(file)
        @sandbox_file_names[sandbox_file.sandbox_name] = file.filename.to_s
        "#{file.filename} -> #{sandbox_file.sandbox_name} (#{file.content_type}, #{file.byte_size} bytes)"
      end

      [
        raw,
        "",
        "The user uploaded #{file_instructions.size} file(s). Read each file thoroughly, then consult your reference materials and verify any legal claims before responding:",
        *file_instructions
      ].join("\n").strip
    end

    def copy_to_sandbox(file)
      FileUtils.mkdir_p(@sandbox_path)

      sandbox_name = @sandbox_name_for.call(file)
      dest = File.join(@sandbox_path, sandbox_name)

      resolved = Pathname.new(dest).cleanpath.to_s
      unless resolved.start_with?(@sandbox_path)
        raise ArgumentError, "Filename escapes sandbox: #{sandbox_name}"
      end

      File.open(dest, "wb") { |f| f.write(file.download) }
      Placement.new(sandbox_name, dest)
    end

    # Tiny value pair returned by copy_to_sandbox: the canonical filename
    # the agent should read by, and the on-disk path the file ended up at.
    # Internal to UploadedFilesPrompt — the caller (UploadedFilesPrompt
    # itself) only needs the sandbox_name to embed in the prompt text.
    Placement = Struct.new(:sandbox_name, :path) do
      def to_s
        path
      end
    end
  end
end
