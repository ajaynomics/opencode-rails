# frozen_string_literal: true

require "test_helper"
require "ripper"

class ReadmeTest < Minitest::Test
  README_PATH = File.expand_path("../README.md", __dir__)
  GEMFILE_PATH = File.expand_path("../Gemfile", __dir__)

  def setup
    @readme = File.read(README_PATH)
    @quickstart = @readme[/^## Quickstart\n(?<body>.*?)(?=^## )/m, :body]
    refute_nil @quickstart, "README must retain a Quickstart section"
  end

  def test_quickstart_turn_call_documents_every_required_keyword
    turn_call = @quickstart[/Opencode::Turn\.new\((?<args>.*?)^\s*\)\.call/m, :args]
    refute_nil turn_call, "Quickstart must contain an Opencode::Turn.new(...).call example"

    documented = turn_call.scan(/^\s*([a-z_]+):/).flatten.map(&:to_sym)
    parameters = Opencode::Turn.instance_method(:initialize).parameters
    required = parameters.filter_map { |kind, name| name if kind == :keyreq }
    accepted = parameters.filter_map { |kind, name| name if %i[keyreq key].include?(kind) }

    assert_empty required - documented,
      "Quickstart is missing required Turn keywords: #{(required - documented).join(", ")}"
    assert_empty documented - accepted,
      "Quickstart uses unsupported Turn keywords: #{(documented - accepted).join(", ")}"
    refute_includes documented, :session
  end

  def test_readme_ruby_fences_parse
    ruby_fences = @readme.scan(/```ruby\n(.*?)```/m).flatten
    refute_empty ruby_fences

    ruby_fences.each_with_index do |source, index|
      assert Ripper.sexp(source), "README Ruby fence #{index + 1} has invalid syntax"
    end
  end

  def test_install_contract_tracks_candidate_versions_and_client_source
    gemfile = File.read(GEMFILE_PATH)
    client_ref = gemfile[/gem "opencode-ruby".*?ref:\s*"([0-9a-f]{40})"/m, 1]

    refute_nil client_ref, "Gemfile must pin opencode-ruby to an exact commit"
    assert_includes @readme, %(gem "opencode-ruby", "= #{Opencode::VERSION}")
    assert_includes @readme, %(gem "opencode-rails", "= #{Opencode::RAILS_VERSION}")
    assert_includes @readme, %(ref: "#{client_ref}")
    assert_includes @readme,
      "`opencode-rails` #{Opencode::RAILS_VERSION} is a release candidate"
    assert_includes @readme, "pushing a `v*` tag does not guarantee publication"
  end

  def test_quickstart_uses_current_fail_closed_permission_rules
    refute_match(/\{\s*type:/, @quickstart)
    assert_includes @quickstart, '{ permission: "bash", pattern: "*", action: "deny" }'
    assert_includes @quickstart, '{ permission: "external_directory", pattern: "*", action: "deny" }'
    assert_includes @quickstart, '{ permission: "edit", pattern: "*", action: "deny" }'
    assert_includes @quickstart, 'permission: "edit",'
    assert_includes @quickstart, 'action: "allow"'
  end

  def test_quickstart_uses_the_enqueued_user_message
    assert_includes @quickstart, "def perform(assistant_message, user_message)"
    refute_includes @quickstart, ".where(role: :user).last"
  end

  def test_instrumentation_docs_match_the_configured_tracer_prefix
    assert_includes @readme, "`assistant.response.started`"
    assert_includes @readme, "Turn events flow through the injected tracer"
  end
end
