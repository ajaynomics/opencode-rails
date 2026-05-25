# frozen_string_literal: true

require "test_helper"

# Contract smoke for Opencode::Turn (the orchestrator) and its inner
# Result value object. Behavioral coverage (the full send -> stream ->
# recover -> finalize loop) lives in the host application — Turn needs
# an Opencode::Client, an AR Message, a subject record, etc., which are
# all integration-level concerns.
class Opencode::TurnTest < Minitest::Test
  REQUIRED_INIT_KEYS = %i[
    message subject query_text client session_for observer_factory
    system_context agent_name tracer
  ].freeze

  OPTIONAL_INIT_KEYS = %i[
    on_finalized on_turn_finished on_activity_tick
    empty_stream_retry_delay final_exchange_timeout
    final_exchange_retry_delay error_fallback_content error_feature
  ].freeze

  def test_required_keyword_arguments
    params = Opencode::Turn.instance_method(:initialize).parameters
    required = params.select { |kind, _| kind == :keyreq }.map(&:last).sort

    assert_equal REQUIRED_INIT_KEYS.sort, required,
      "Turn's required keyword args drifted. Expected: #{REQUIRED_INIT_KEYS.sort}, got: #{required}"
  end

  def test_optional_keyword_arguments_match_documented_surface
    params = Opencode::Turn.instance_method(:initialize).parameters
    optional = params.select { |kind, _| kind == :key }.map(&:last).sort

    assert_equal OPTIONAL_INIT_KEYS.sort, optional,
      "Turn's optional keyword args drifted. Expected: #{OPTIONAL_INIT_KEYS.sort}, got: #{optional}"
  end

  def test_public_surface_is_call_only
    # Turn is an orchestrator; the only public verb is #call. Everything
    # else is internal. Locking this prevents helpers from accidentally
    # bleeding into the public API.
    assert_equal [ :call ], Opencode::Turn.instance_methods(false)
  end

  def test_result_is_a_value_object_with_status_predicates
    fake_message = Struct.new(:cost, :input_tokens, :output_tokens, keyword_init: true).new(
      cost: 0.012, input_tokens: 100, output_tokens: 50
    )
    result = Opencode::Turn::Result.new(
      status: :completed, message: fake_message, duration_ms: 1234
    )

    assert result.completed?
    refute result.cancelled?
    refute result.errored?
    refute result.failed?
    assert_equal 1234, result.duration_ms
    assert_equal 0.012, result.cost
    assert_equal 100,   result.input_tokens
    assert_equal 50,    result.output_tokens
  end
end
