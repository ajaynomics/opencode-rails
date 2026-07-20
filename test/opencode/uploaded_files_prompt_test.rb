# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"

# Smoke test for Opencode::UploadedFilesPrompt. The sandbox_path:
# inversion (per D14 in the design doc) means we can exercise the
# happy path against a tmpdir without needing Rails / AR / ActiveStorage
# fixtures. Behavioral tests covering ActiveStorage attached_blob
# enumeration live in the host application.
class Opencode::UploadedFilesPromptTest < Minitest::Test
  # Minimal stub for a user message: #content (the raw user text) and
  # #files (an ActiveStorage-like collection with #attached?). Real
  # behavior is exercised in the host's test suite.
  FakeMessage = Struct.new(:content, :files, keyword_init: true)
  EmptyFiles = Struct.new(:attached) do
    def attached? = attached
  end
  AttachedFiles = Class.new(Array) do
    def attached? = true
  end
  FakeUpload = Struct.new(:filename, :content_type, :content, keyword_init: true) do
    def byte_size = content.bytesize
    def download = content
  end

  def setup
    @tmpdir = Dir.mktmpdir("opencode-rails-uploaded-prompt-test-")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  def test_initialize_takes_three_required_keywords
    params = Opencode::UploadedFilesPrompt.instance_method(:initialize).parameters
    required = params.select { |kind, _| kind == :keyreq }.map(&:last).sort

    assert_equal %i[sandbox_name_for sandbox_path user_message], required,
      "UploadedFilesPrompt requires user_message:, sandbox_path:, sandbox_name_for:"
  end

  def test_text_returns_raw_content_when_no_files_attached
    message = FakeMessage.new(content: "hello world", files: EmptyFiles.new(false))
    prompt = Opencode::UploadedFilesPrompt.new(
      user_message:     message,
      sandbox_path:     @tmpdir,
      sandbox_name_for: ->(file) { file.filename.to_s }
    )

    assert_equal "hello world", prompt.text,
      "No attached files => text is the raw user content"
    assert_equal({}, prompt.sandbox_file_names,
      "No attached files => sandbox_file_names map stays empty")
  end

  def test_public_surface
    assert_equal %i[sandbox_file_names text].sort,
      Opencode::UploadedFilesPrompt.instance_methods(false).sort
  end

  def test_copies_an_upload_without_domain_specific_instructions
    upload = FakeUpload.new(filename: "notes.txt", content_type: "text/plain", content: "hello")
    message = FakeMessage.new(content: "summarize", files: AttachedFiles.new([ upload ]))
    prompt = Opencode::UploadedFilesPrompt.new(
      user_message: message,
      sandbox_path: @tmpdir,
      sandbox_name_for: ->(_file) { "upload.txt" }
    )

    assert_equal "hello", File.binread(File.join(@tmpdir, "upload.txt"))
    assert_includes prompt.text, "Read each file thoroughly before responding:"
    refute_includes prompt.text, "legal claims"
    refute_includes prompt.text, "reference materials"
  end

  def test_rejects_a_sibling_prefix_escape
    sandbox = File.join(@tmpdir, "foo")
    sibling = File.join(@tmpdir, "foobar")
    FileUtils.mkdir_p(sibling)
    target = File.join(sibling, "target.txt")
    File.write(target, "safe")
    upload = FakeUpload.new(filename: "notes.txt", content_type: "text/plain", content: "overwritten")
    message = FakeMessage.new(content: "summarize", files: AttachedFiles.new([ upload ]))

    assert_raises(ArgumentError) do
      Opencode::UploadedFilesPrompt.new(
        user_message: message,
        sandbox_path: sandbox,
        sandbox_name_for: ->(_file) { "../foobar/target.txt" }
      )
    end
    assert_equal "safe", File.read(target)
  end

  def test_atomically_replaces_a_destination_symlink_without_following_it
    outside = File.join(@tmpdir, "outside.txt")
    sandbox = File.join(@tmpdir, "sandbox")
    FileUtils.mkdir_p(sandbox)
    File.write(outside, "safe")
    File.symlink(outside, File.join(sandbox, "upload.txt"))
    upload = FakeUpload.new(filename: "notes.txt", content_type: "text/plain", content: "overwritten")
    message = FakeMessage.new(content: "summarize", files: AttachedFiles.new([ upload ]))

    Opencode::UploadedFilesPrompt.new(
      user_message: message,
      sandbox_path: sandbox,
      sandbox_name_for: ->(_file) { "upload.txt" }
    )

    assert_equal "safe", File.read(outside)
    assert_equal "overwritten", File.read(File.join(sandbox, "upload.txt"))
    refute File.symlink?(File.join(sandbox, "upload.txt"))
  end

  def test_retried_copy_refreshes_an_existing_sandbox_file
    sandbox = File.join(@tmpdir, "sandbox")
    FileUtils.mkdir_p(sandbox)
    File.write(File.join(sandbox, "upload.txt"), "stale")
    upload = FakeUpload.new(filename: "notes.txt", content_type: "text/plain", content: "fresh")
    message = FakeMessage.new(content: "summarize", files: AttachedFiles.new([ upload ]))

    Opencode::UploadedFilesPrompt.new(
      user_message: message,
      sandbox_path: sandbox,
      sandbox_name_for: ->(_file) { "upload.txt" }
    )

    assert_equal "fresh", File.read(File.join(sandbox, "upload.txt"))
  end

  def test_rejects_a_sandbox_root_replaced_during_the_copy
    sandbox = File.join(@tmpdir, "sandbox")
    moved_sandbox = File.join(@tmpdir, "moved-sandbox")
    FileUtils.mkdir_p(sandbox)
    upload = FakeUpload.new(filename: "notes.txt", content_type: "text/plain", content: "private")
    message = FakeMessage.new(content: "summarize", files: AttachedFiles.new([ upload ]))
    create = Tempfile.method(:create)
    replace_root = lambda do |*args, **kwargs, &block|
      File.rename(sandbox, moved_sandbox)
      FileUtils.mkdir_p(sandbox)
      create.call(*args, **kwargs, &block)
    end

    Tempfile.stub(:create, replace_root) do
      assert_raises(ArgumentError) do
        Opencode::UploadedFilesPrompt.new(
          user_message: message,
          sandbox_path: sandbox,
          sandbox_name_for: ->(_file) { "upload.txt" }
        )
      end
    end

    refute File.exist?(File.join(sandbox, "upload.txt"))
    refute File.exist?(File.join(moved_sandbox, "upload.txt"))
  end

  def test_new_upload_uses_the_normal_umask_file_mode
    upload = FakeUpload.new(filename: "notes.txt", content_type: "text/plain", content: "hello")
    message = FakeMessage.new(content: "summarize", files: AttachedFiles.new([ upload ]))

    Opencode::UploadedFilesPrompt.new(
      user_message: message,
      sandbox_path: @tmpdir,
      sandbox_name_for: ->(_file) { "upload.txt" }
    )

    assert_equal 0o666 & ~File.umask, File.stat(File.join(@tmpdir, "upload.txt")).mode & 0o777
  end

  def test_retried_copy_preserves_an_existing_file_mode
    existing = File.join(@tmpdir, "upload.txt")
    File.write(existing, "stale")
    File.chmod(0o640, existing)
    upload = FakeUpload.new(filename: "notes.txt", content_type: "text/plain", content: "fresh")
    message = FakeMessage.new(content: "summarize", files: AttachedFiles.new([ upload ]))

    Opencode::UploadedFilesPrompt.new(
      user_message: message,
      sandbox_path: @tmpdir,
      sandbox_name_for: ->(_file) { "upload.txt" }
    )

    assert_equal 0o640, File.stat(existing).mode & 0o777
  end
end
