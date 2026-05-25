# frozen_string_literal: true

require "test_helper"
require "fileutils"
require "tmpdir"
require "marcel"  # SandboxFile (yielded by Sandbox#files) needs marcel

# Smoke test for Opencode::Sandbox: instantiate against a real tmpdir,
# verify #path, #exists?, and that #files / #file return empty / nil
# when no sandbox files are present. Behavioral coverage of actual file
# enumeration lives in the host application where real per-product
# sandbox configurations exercise the path.
class Opencode::SandboxTest < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("opencode-rails-sandbox-test-")
  end

  def teardown
    FileUtils.remove_entry(@tmpdir) if @tmpdir && File.exist?(@tmpdir)
  end

  def test_path_and_exists_when_directory_present
    sandbox = Opencode::Sandbox.new(path: @tmpdir)
    assert_equal @tmpdir, sandbox.path
    assert sandbox.exists?
  end

  def test_exists_false_when_path_missing
    sandbox = Opencode::Sandbox.new(path: File.join(@tmpdir, "missing"))
    refute sandbox.exists?
  end

  def test_files_returns_enumerator_yielding_nothing_when_empty
    sandbox = Opencode::Sandbox.new(path: @tmpdir)
    # No block given => Enumerator.
    assert_kind_of Enumerator, sandbox.files
    assert_equal [], sandbox.files.to_a
  end

  def test_files_yields_sandbox_files_for_real_entries
    File.write(File.join(@tmpdir, "notes.md"), "x")
    File.write(File.join(@tmpdir, "map.md"),   "y")

    sandbox = Opencode::Sandbox.new(path: @tmpdir)
    basenames = sandbox.files.map(&:basename).sort
    assert_equal %w[map.md notes.md], basenames
  end

  def test_file_returns_nil_for_missing_relative_name
    sandbox = Opencode::Sandbox.new(path: @tmpdir)
    assert_nil sandbox.file("nope.txt")
  end
end
