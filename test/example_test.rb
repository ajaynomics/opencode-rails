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
    assert_includes SOURCE, '{ permission: "bash", pattern: "*", action: "deny" }'
    assert_includes SOURCE, '{ permission: "external_directory", pattern: "*", action: "deny" }'
    assert_includes SOURCE, '{ permission: "edit", pattern: "*", action: "deny" }'
  end
end
