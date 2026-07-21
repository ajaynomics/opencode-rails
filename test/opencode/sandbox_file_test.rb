# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "socket"
require "tmpdir"
require "marcel"  # SandboxFile#content_type uses Marcel::MimeType.for

# Smoke test for Opencode::SandboxFile: instantiate against a real
# pathname, verify basename/size/content/content_type readers and the
# identity conversion to Opencode::Artifact via #as_artifact.
class Opencode::SandboxFileTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("opencode-rails-sandbox-file-test-")
    @outside_dir = Dir.mktmpdir("opencode-rails-sandbox-file-outside-")
    @path = File.join(@tmpdir, "notes.md")
    File.write(@path, "# hello\nworld\n")
    # SandboxFile uses `start_with?` against this prefix to detect path
    # escape; it expects a String with trailing separator so that
    # /sandbox-1 doesn't false-positive on /sandbox-10/foo.
    @sandbox_prefix = File.join(@tmpdir, "")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
    FileUtils.remove_entry(@outside_dir) if @outside_dir && File.exist?(@outside_dir)
  end

  def test_basic_readers
    file = Opencode::SandboxFile.new(
      path: @path, sandbox_prefix: @sandbox_prefix, max_bytes: 10_000
    )

    assert_equal "notes.md", file.basename
    assert file.size.positive?
    assert_equal "# hello\nworld\n", file.content
    assert file.safe?, "small text file inside sandbox should be safe"
  end

  def test_content_type_detection_via_marcel
    file = Opencode::SandboxFile.new(
      path: @path, sandbox_prefix: @sandbox_prefix, max_bytes: 10_000
    )
    # Marcel detects .md as text/markdown.
    assert_match(/markdown|text/, file.content_type)
  end

  def test_safe_rejects_files_over_size_cap
    file = Opencode::SandboxFile.new(
      path: @path, sandbox_prefix: @sandbox_prefix, max_bytes: 5
    )
    refute file.safe?, "file larger than max_bytes must be unsafe"
  end

  def test_as_artifact_returns_opencode_artifact_value
    file = Opencode::SandboxFile.new(
      path: @path, sandbox_prefix: @sandbox_prefix, max_bytes: 10_000
    )

    artifact = file.as_artifact
    assert_instance_of Opencode::Artifact, artifact
    assert_equal "notes.md", artifact.filename
    assert_equal "# hello\nworld\n", artifact.content
  end

  def test_content_rejects_a_file_replaced_by_an_outside_symlink
    file = Opencode::SandboxFile.new(
      path: @path, sandbox_prefix: @sandbox_prefix, max_bytes: 10_000
    )
    outside = File.join(@outside_dir, "private.txt")
    File.write(outside, "private")
    assert file.safe?

    File.unlink(@path)
    File.symlink(outside, @path)

    assert_raises(Opencode::SandboxFile::UnsafeFileError) { file.content }
  end

  def test_safe_rejects_a_hard_link
    File.unlink(@path)
    outside = File.join(@outside_dir, "private.txt")
    File.write(outside, "private")
    File.link(outside, @path)
    file = Opencode::SandboxFile.new(
      path: @path, sandbox_prefix: @sandbox_prefix, max_bytes: 10_000
    )

    refute file.safe?
  end

  def test_content_rejects_a_hard_link_added_immediately_before_open
    file = Opencode::SandboxFile.new(
      path: @path, sandbox_prefix: @sandbox_prefix, max_bytes: 10_000
    )
    outside_link = File.join(@outside_dir, "linked-notes.md")
    real_open = File.method(:open)
    link_before_open = lambda do |path, mode, *args, **kwargs, &block|
      File.link(path, outside_link)
      real_open.call(path, mode, *args, **kwargs, &block)
    end

    File.stub(:open, link_before_open) do
      assert_raises(Opencode::SandboxFile::UnsafeFileError) { file.content }
    end
  end

  def test_content_rejects_an_inode_that_grows_past_the_cap_while_reading
    file = Opencode::SandboxFile.new(
      path: @path, sandbox_prefix: @sandbox_prefix, max_bytes: 20
    )
    real_open = File.method(:open)
    grow_on_read = lambda do |path, *args, **kwargs, &block|
      real_open.call(path, *args, **kwargs) do |opened|
        proxy = Object.new
        proxy.define_singleton_method(:stat) { opened.stat }
        proxy.define_singleton_method(:read) do |length = nil|
          real_open.call(path, "ab") { |writer| writer.write("x" * 100) }
          opened.read(length)
        end
        block.call(proxy)
      end
    end

    File.stub(:open, grow_on_read) do
      assert_raises(Opencode::SandboxFile::UnsafeFileError) { file.content }
    end
  end

  def test_content_rejects_a_fifo_swapped_in_immediately_before_open_without_blocking
    file = Opencode::SandboxFile.new(
      path: @path, sandbox_prefix: @sandbox_prefix, max_bytes: 10_000
    )
    real_open = File.method(:open)
    swap_before_open = lambda do |path, mode, *args, **kwargs, &block|
      File.unlink(path)
      File.mkfifo(path)
      assert_kind_of Integer, mode
      assert_operator mode & File::NONBLOCK, :>, 0
      assert_operator mode & File::NOFOLLOW, :>, 0
      real_open.call(path, mode, *args, **kwargs, &block)
    end

    File.stub(:open, swap_before_open) do
      assert_raises(Opencode::SandboxFile::UnsafeFileError) { file.content }
    end
  end

  def test_content_rejects_a_symlink_swapped_in_immediately_before_open
    file = Opencode::SandboxFile.new(
      path: @path, sandbox_prefix: @sandbox_prefix, max_bytes: 10_000
    )
    outside = File.join(@outside_dir, "private.txt")
    File.write(outside, "private")
    real_open = File.method(:open)
    swap_before_open = lambda do |path, mode, *args, **kwargs, &block|
      File.unlink(path)
      File.symlink(outside, path)
      real_open.call(path, mode, *args, **kwargs, &block)
    end

    File.stub(:open, swap_before_open) do
      assert_raises(Opencode::SandboxFile::UnsafeFileError) { file.content }
    end
  end

  def test_safe_rejects_a_socket_swapped_in_immediately_before_open
    file = Opencode::SandboxFile.new(
      path: @path, sandbox_prefix: @sandbox_prefix, max_bytes: 10_000
    )
    real_open = File.method(:open)
    socket = nil
    swap_before_open = lambda do |path, mode, *args, **kwargs, &block|
      File.unlink(path)
      socket = UNIXServer.new(path)
      real_open.call(path, mode, *args, **kwargs, &block)
    end

    File.stub(:open, swap_before_open) do
      refute file.safe?
    end
  ensure
    socket&.close
  end

  def test_safe_fails_closed_when_secure_open_flags_are_unavailable
    file = Opencode::SandboxFile.new(
      path: @path, sandbox_prefix: @sandbox_prefix, max_bytes: 10_000
    )
    real_const_defined = File.method(:const_defined?)
    const_defined = lambda do |name, inherit = true|
      name == :NOFOLLOW ? false : real_const_defined.call(name, inherit)
    end

    File.stub(:const_defined?, const_defined) do
      refute file.safe?
    end
  end

  def test_content_returns_binary_empty_string_for_a_zero_byte_file
    File.write(@path, "")
    file = Opencode::SandboxFile.new(
      path: @path, sandbox_prefix: @sandbox_prefix, max_bytes: 20
    )

    assert_equal "".b, file.content
  end
end
