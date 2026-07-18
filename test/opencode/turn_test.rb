# frozen_string_literal: true

require "test_helper"

# Contract smoke for Opencode::Turn (the orchestrator) and its inner
# Result value object. Most ActiveRecord behavior lives in host applications,
# but the subscribe-before-prompt ordering is a cross-gem transport contract
# and belongs here so a host cannot silently bypass opencode-ruby's guarantee.
class Opencode::TurnTest < Minitest::Test
  SESSION_ID = "ses_turn_test"

  class FakeMessage
    attr_reader :id, :finalized, :error_content
    attr_accessor :cost, :input_tokens, :output_tokens, :tool_calls_json

    def initialize
      @id = 12
    end

    def reload = self
    def cancelled? = false

    def finalize!(**attrs)
      @finalized = attrs
      @cost = attrs[:cost]
      @input_tokens = attrs[:input_tokens]
      @output_tokens = attrs[:output_tokens]
      @tool_calls_json = attrs[:tool_calls_json]
      true
    end

    def error!(content)
      @error_content = content
    end
  end

  FakeSubject = Struct.new(:id, :opencode_session_id, keyword_init: true)

  class FakeSession
    def ensure!(_client) = SESSION_ID
    def just_created? = false
  end

  class FakeObserver
    def watch(_reply); end
  end

  class OrderedClient
    attr_reader :order, :prompt_count, :message_reads

    def initialize(prompt_error: nil)
      @order = []
      @prompt_count = 0
      @message_reads = 0
      @prompt_error = prompt_error
    end

    def get_messages(_session_id)
      @message_reads += 1
      @order << (@prompt_count.zero? ? :messages_before : :messages_after)
      return [] if @prompt_count.zero?

      [
        { info: { role: "user" }, parts: [ { type: "text", text: "ping" } ] },
        {
          info: {
            role: "assistant", finish: "stop",
            time: { created: 1, completed: 2 },
            cost: 0.01,
            tokens: { input: 2, output: 1 }
          },
          parts: [ { type: "text", text: "pong" } ]
        }
      ]
    end

    def send_message_async(session_id, text, agent:, system:)
      @prompt_count += 1
      @order << :prompt
      raise @prompt_error if @prompt_error

      raise "wrong prompt" unless session_id == SESSION_ID && text == "ping"
      raise "wrong routing" unless agent == "test-agent" && system == "test-system"

      {}
    end

    def stream_events(session_id:, reply:, on_activity_tick:, on_subscribed:)
      raise "wrong session" unless session_id == SESSION_ID
      raise "missing reply" unless reply.is_a?(Opencode::Reply)
      raise "missing activity callback" unless on_activity_tick.respond_to?(:call)

      @order << :sse_ready
      on_subscribed.call
      @order << :sse_reconnected
      on_subscribed.call
      yield(
        type: "message.part.delta",
        properties: { sessionID: SESSION_ID, partID: "p1", field: "text", delta: "pong" }
      )
      yield(
        type: "session.status",
        properties: { sessionID: SESSION_ID, status: { type: "idle" } }
      )
    end
  end
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

  def test_turn_subscribes_before_prompt_and_never_reprompts_on_reconnect
    client = OrderedClient.new
    message = FakeMessage.new
    results = []

    build_turn(client:, message:, results:).call

    assert_equal 1, client.prompt_count
    assert_equal(
      [ :messages_before, :sse_ready, :prompt, :sse_reconnected, :messages_after ],
      client.order
    )
    assert_equal "pong", message.finalized.fetch(:content)
    assert_nil message.error_content
    assert results.last.completed?
  end

  def test_turn_does_not_recover_or_retry_an_ambiguous_prompt_failure
    client = OrderedClient.new(prompt_error: Net::ReadTimeout.new("prompt timed out"))
    message = FakeMessage.new
    results = []

    build_turn(client:, message:, results:).call

    assert_equal 1, client.prompt_count
    assert_equal 1, client.message_reads
    assert_nil message.finalized
    assert_equal Opencode::Turn::ERROR_FALLBACK_CONTENT, message.error_content
    assert results.last.failed?
    assert_instance_of Net::ReadTimeout, results.last.error
  end

  private

  def build_turn(client:, message:, results:)
    Opencode::Turn.new(
      message: message,
      subject: FakeSubject.new(id: 34, opencode_session_id: SESSION_ID),
      query_text: "ping",
      client: client,
      session_for: FakeSession.new,
      observer_factory: ->(_message) { FakeObserver.new },
      system_context: ->(_subject) { "test-system" },
      agent_name: ->(_subject) { "test-agent" },
      tracer: ->(_name, **_payload) {},
      on_turn_finished: ->(result) { results << result },
      empty_stream_retry_delay: 0,
      final_exchange_timeout: 0,
      final_exchange_retry_delay: 0
    )
  end
end
