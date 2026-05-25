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
end
