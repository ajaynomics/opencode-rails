# frozen_string_literal: true

require "test_helper"
require "ripper"

class ExampleTest < Minitest::Test
  PATH = File.expand_path("../examples/rails_integration.rb", __dir__)
  SOURCE = File.read(PATH)

  def test_example_parses
    assert Ripper.sexp(SOURCE)
  end

  def test_example_uses_turn_collaborator_contracts
    assert_includes SOURCE, "def perform(assistant_message, user_message)"
    assert_includes SOURCE, "session_for:    session"
    assert_includes SOURCE, "system_context: ->(record)"
    assert_includes SOURCE, "agent_name:     ->(_record)"
    assert_includes SOURCE, '{ "build" }'
    assert_includes SOURCE, "def watch(reply)"
    assert_includes SOURCE, "include Opencode::ReplyObserver"
    assert_includes SOURCE, 'ActiveSupport::Notifications.instrument("assistant.#{name}", payload)'
    refute_includes SOURCE, 'Opencode::Tracer.new(prefix: "opencode.")'
    refute_includes SOURCE, ".order(:created_at).last"
  end

  def test_example_uses_reply_indexes_for_dom_identity
    assert_includes SOURCE, 'target: "part_#{index}_message_#{@message.id}"'
    assert_includes SOURCE, "locals: { part: part, index: index, message: @message }"
    refute_includes SOURCE, "part['id']"
  end

  def test_example_does_not_claim_unimplemented_mid_stream_persistence
    refute_includes SOURCE, "Mid-stream parts_json snapshotting"
    refute_includes SOURCE, "update_columns"
  end

  def test_example_uses_current_fail_closed_permission_rules
    refute_match(/\{\s*type:/, SOURCE)
    assert_includes SOURCE, 'working_directory = File.realpath(ENV.fetch("OPENCODE_WORKING_DIRECTORY"))'
    assert_includes SOURCE, "directory: working_directory"
    assert_includes SOURCE, '{ permission: "*", pattern: "*", action: "deny" }'
    refute_includes SOURCE, 'action: "allow"'
    assert_includes SOURCE, "OPENCODE_DISABLE_PROJECT_CONFIG=1"
    refute_includes SOURCE, "ConversationSandbox"
    assert_includes SOURCE, "permissions only when it creates a session"
    assert_match(/recreate persisted sessions/i, SOURCE)
    refute_includes SOURCE, "Sandbox:"
  end

  def test_example_permission_order_denies_every_tool
    body = SOURCE[/def permission_rules_for\(_conversation\)\n(?<body>.*?)^  end/m, :body]
    rules = eval(body, binding, PATH)
    action_for = lambda do |permission, pattern|
      rules.reverse.find do |rule|
        (rule.fetch(:permission) == "*" || rule.fetch(:permission) == permission) &&
          (rule.fetch(:pattern) == "*" || rule.fetch(:pattern) == pattern)
      end.fetch(:action)
    end

    assert_equal "deny", action_for.call("read", "arbitrary/worktree/path")
    assert_equal "deny", action_for.call("edit", "arbitrary/worktree/path")
    assert_equal "deny", action_for.call("external_directory", "/outside/*")
    assert_equal "deny", action_for.call("grep", "secret")
    assert_equal "deny", action_for.call("lsp", "*")
  end
end
