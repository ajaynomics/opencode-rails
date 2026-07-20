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
  # guarded: generated names must be basenames, and all writes stay anchored
  # to an opened directory handle even if the sandbox path is replaced.
  # A temporary file is renamed into place so destination symlinks are
  # replaced rather than followed. Retried jobs can refresh existing copies.
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
        "The user uploaded #{file_instructions.size} file(s). Read each file thoroughly before responding:",
        *file_instructions
      ].join("\n").strip
    end

    def copy_to_sandbox(file)
      sandbox_path = Pathname.new(@sandbox_path).expand_path
      FileUtils.mkdir_p(sandbox_path)
      sandbox_stat = File.lstat(sandbox_path)
      unless sandbox_stat.directory? && !sandbox_stat.symlink?
        raise ArgumentError, "Sandbox root must be a directory, not a symlink: #{sandbox_path}"
      end

      sandbox_name = @sandbox_name_for.call(file).to_s
      unless sandbox_name == File.basename(sandbox_name) && !%w[. ..].include?(sandbox_name)
        raise ArgumentError, "Filename escapes sandbox: #{sandbox_name}"
      end

      File.open(sandbox_path, File::RDONLY) do |directory|
        opened_stat = directory.stat
        unless opened_stat.directory? && same_file?(sandbox_stat, opened_stat)
          raise ArgumentError, "Sandbox root changed while opening: #{sandbox_path}"
        end

        directory_path = directory_handle_path(directory)
        dest = File.join(directory_path, sandbox_name)
        mode = destination_mode(dest)

        Tempfile.create([ ".opencode-upload-", ".tmp" ], directory_path) do |temp|
          temp.binmode
          temp.write(file.download)
          temp.flush
          temp.chmod(mode)
          File.rename(temp.path, dest)

          unless same_file_at_path?(sandbox_path, opened_stat)
            File.unlink(dest)
            raise ArgumentError, "Sandbox root changed during upload: #{sandbox_path}"
          end
        end
      end
      Placement.new(sandbox_name, sandbox_path.join(sandbox_name).to_s)
    end

    def directory_handle_path(directory)
      stat = directory.stat
      [ "/proc/self/fd/#{directory.fileno}", "/dev/fd/#{directory.fileno}" ].find do |path|
        same_file?(File.stat(path), stat)
      rescue Errno::ENOENT
        false
      end || raise(ArgumentError, "Platform cannot anchor writes to the opened sandbox directory")
    end

    def destination_mode(path)
      stat = File.lstat(path)
      return stat.mode & 0o777 if stat.file? && !stat.symlink?

      0o666 & ~File.umask
    rescue Errno::ENOENT
      0o666 & ~File.umask
    end

    def same_file_at_path?(path, expected)
      current = File.lstat(path)
      current.directory? == expected.directory? && !current.symlink? && same_file?(current, expected)
    rescue Errno::ENOENT
      false
    end

    def same_file?(left, right)
      left.dev == right.dev && left.ino == right.ino
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
