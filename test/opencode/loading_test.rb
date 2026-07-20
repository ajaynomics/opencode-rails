# frozen_string_literal: true

require "test_helper"
require "open3"

# Smoke test: every constant the gem promises is defined and points at
# the right kind of object. If require "opencode-rails" loads cleanly,
# this passes. If the require chain drifts or a file fails to load,
# this catches it before downstream apps do.
class Opencode::LoadingTest < Minitest::Test
  GEM_PROVIDED_CONSTANTS = %w[
    Session Turn Exchange Artifact Sandbox SandboxFile
    Transform Impostor MessageArtifacts UploadedFilesPrompt
    ToolDisplay ErrorReporter
  ].freeze

  # Reply / Tracer / Client / etc. ship in opencode-ruby and are
  # transitively required by opencode-rails' umbrella. Verify the
  # require chain pulled them in.
  TRANSITIVE_CONSTANTS_FROM_OPENCODE_RUBY = %w[
    Client Reply ReplyObserver Tracer Prompts
    ResponseParser ToolPart PartSource Todo
    Instrumentation Error
  ].freeze

  def test_gem_provides_expected_constants
    GEM_PROVIDED_CONSTANTS.each do |name|
      assert Opencode.const_defined?(name),
        "Expected Opencode::#{name} to be defined after `require \"opencode-rails\"`"
    end
  end

  def test_transitively_loads_opencode_ruby_constants
    TRANSITIVE_CONSTANTS_FROM_OPENCODE_RUBY.each do |name|
      assert Opencode.const_defined?(name),
        "Expected Opencode::#{name} to be defined transitively via opencode-ruby"
    end
  end

  # Match the gem's own lib path, not merely any parent directory. GitHub's
  # checkout layout nests Bundler under /opencode-rails/opencode-rails, so a
  # broad directory-name assertion falsely classifies a bundled
  # opencode-ruby source path as belonging to this gem.
  GEM_SOURCE_PATTERN = lambda do |name, file|
    %r{/#{Regexp.escape(name)}(?:-[^/]+)?/lib/opencode/#{Regexp.escape(file)}\.rb\z}
  end

  def test_session_constant_points_at_this_gem
    location = Opencode::Session.instance_method(:initialize).source_location.first
    expected = File.expand_path("../../lib/opencode/session.rb", __dir__)
    assert_equal expected, File.expand_path(location),
      "Expected Opencode::Session to be loaded from this opencode-rails checkout"
  end

  def test_client_constant_points_at_opencode_ruby
    location = Opencode::Client.instance_method(:initialize).source_location.first
    assert_match GEM_SOURCE_PATTERN.call("opencode-ruby", "client"), location,
      "Expected Opencode::Client to come from opencode-ruby, got: #{location}"
    refute_match GEM_SOURCE_PATTERN.call("opencode-rails", "client"), location,
      "Opencode::Client must NOT come from opencode-rails (it's an opencode-ruby class)"
  end

  def test_version_constant
    assert_match(/\A\d+\.\d+\.\d+/, Opencode::RAILS_VERSION)
  end

  def test_no_opencode_rails_module
    # Defining Opencode::Rails as a module would shadow ::Rails for any
    # host code that references top-level Rails.* from inside the
    # Opencode:: namespace (e.g. lib/opencode/containers/container.rb).
    # Verify the namespace stays clean — version lives at
    # Opencode::RAILS_VERSION, not Opencode::Rails::VERSION.
    refute Opencode.const_defined?(:Rails),
      "Opencode::Rails must not be defined — it would shadow ::Rails inside the Opencode namespace"
  end

  def test_umbrella_require_loads_runtime_standard_libraries
    root = File.expand_path("../..", __dir__)
    script = <<~'RUBY'
      require "opencode-rails"
      abort "StringIO missing" unless defined?(StringIO)
      abort "Marcel missing" unless defined?(Marcel::MimeType)
      abort "FileUtils missing" unless defined?(FileUtils)
      abort "Tempfile missing" unless defined?(Tempfile)
    RUBY

    _stdout, stderr, status = Open3.capture3(
      Gem.ruby,
      "-I#{File.join(root, "lib")}",
      "-e",
      script
    )

    assert status.success?, stderr
  end
end
