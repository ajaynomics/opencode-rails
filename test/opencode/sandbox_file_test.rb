# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "marcel"  # SandboxFile#content_type uses Marcel::MimeType.for

# Smoke test for Opencode::SandboxFile: instantiate against a real
# pathname, verify basename/size/content/content_type readers and the
# identity conversion to Opencode::Artifact via #as_artifact.
class Opencode::SandboxFileTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("opencode-rails-sandbox-file-test-")
    @path = File.join(@tmpdir, "notes.md")
    File.write(@path, "# hello\nworld\n")
    # SandboxFile uses `start_with?` against this prefix to detect path
    # escape; it expects a String with trailing separator so that
    # /sandbox-1 doesn't false-positive on /sandbox-10/foo.
    @sandbox_prefix = File.join(@tmpdir, "")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
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
end
