# frozen_string_literal: true

require "test_helper"
require "ripper"

class ReadmeTest < Minitest::Test
  README_PATH = File.expand_path("../README.md", __dir__)

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
end
