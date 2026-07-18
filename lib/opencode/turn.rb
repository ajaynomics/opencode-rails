# frozen_string_literal: true

module Opencode
  # Opencode::Turn is an INTERNAL procedure object.
  #
  # Its constructor signature (14 keyword arguments) is NOT part of the
  # gem's public API. Use the higher-level affordances on
  # Opencode::Client instead:
  #
  #   Opencode::Client#stream(session_id, prompt) { |part| ... }
  #     → block-form streaming for live partials, returns Reply::Result
  #
  #   Opencode::Client#send_message(session_id, prompt)
  #     → sync send-and-poll for the simple no-streaming case
  #
  # If you find yourself instantiating Turn directly, file an issue —
  # that's a signal we need a higher-level API you can't yet reach.
  #
  # Subject to change without major-version bump. See lib/opencode/CLAUDE.md
  # 'Conventions and known debt' section.
  # One streaming turn against an Opencode session.
  #
  # A "turn" is one user-message + one assistant-response cycle. Turn drives
  # that cycle to completion: ensure the session, send the query, stream
  # events into a Reply, recover from common failures, persist the final
  # assistant message, and produce an Opencode::Turn::Result.
  #
  # Honest about the shape: this is a procedure object that wraps the data
  # of one turn (message, subject, exchange, reply) with the strategies
  # that drive it (session lifecycle, observer, system context, agent name)
  # and the sinks that consume the result (tracer, callbacks). The design
  # alternatives — abstract base class with hook methods, or factoring out
  # an explicit Pipeline state machine — were considered. The first is the
  # POODR-flagged inheritance-for-code-reuse anti-pattern. The second adds
  # a layer without changing the size of the procedure. We picked the
  # smallest honest shape.
  #
  # Composition over inheritance: every product-specific concern is a
  # collaborator passed in. Turn never sees any specific product by
  # name — the orchestration shape is uniform.
  #
  # Collaborators
  # -------------
  #
  # session_for      Opencode::Session-shaped. Responds to:
  #                  - #ensure!(client) -> session_id String
  #                  - #recreate!(client) -> session_id String
  #                  - #just_created? -> Boolean (true iff the most recent
  #                    ensure!/recreate! actually minted a fresh session).
  #
  # observer_factory callable: ->(message) returning an observer that
  #                  responds to #watch(reply). Concretely:
  #                  ->(message) { MyApp::ReplyStream.new(message: message) }.
  #
  # system_context   callable: ->(subject) -> String system prompt.
  #
  # agent_name       callable: ->(subject) -> String agent slug.
  #
  # tracer           Opencode::Tracer-shaped. Responds to
  #                  #call(name, **payload). Receives unprefixed event
  #                  names; the tracer prepends the product namespace.
  #
  # on_finalized       callable: ->(message, exchange) called after the
  #                    assistant message is persisted in :completed.
  #                    Errors raised here are reported and contained;
  #                    they do not flip the message back to :error.
  #
  # on_turn_finished   callable: ->(result) where result is an
  #                    Opencode::Turn::Result. Called once at the end of
  #                    every turn (any path). Errors raised here are
  #                    reported and contained.
  #
  # on_activity_tick   callable: ->(subject) called periodically during
  #                    streaming so callers can keep the user's container
  #                    warm. Default: no-op.
  #
  # Required record-shape contract on `subject`:
  #
  #   subject.id
  #   subject.opencode_session_id
  #
  # Required record-shape contract on `message` (assistant message):
  #
  #   message.id
  #   message.reload
  #   message.cancelled?
  #   message.finalize!(**attrs)         # CAS update from :pending state
  #   message.update!(content:, status:) # for cancellation + error fallback
  #
  # Public API: only `#call`. Never raises in normal operation; all errors
  # are translated into a marked-error message and an on_turn_finished
  # callback with `result.failed?`.
  class Turn
    DEFAULT_EMPTY_STREAM_RETRY_DELAY = 2.seconds
    DEFAULT_FINAL_EXCHANGE_TIMEOUT = 120.seconds
    DEFAULT_FINAL_EXCHANGE_RETRY_DELAY = 2.seconds
    ACTIVITY_TOUCH_INTERVAL = 5.minutes.to_i
    ERROR_FALLBACK_CONTENT = "Sorry, an error occurred while generating this response."

    # The result of running one Turn. A value object so the Symbol-vs-String
    # status confusion that lived inside the old `emit_turn_finished` payload
    # has one source of truth: the Result. Callbacks ask `result.completed?`;
    # trace consumers ask `result.trace_payload`.
    class Result
      attr_reader :status, :message, :duration_ms, :cost,
        :input_tokens, :output_tokens, :error

      # status: :completed | :cancelled | :error | :failed
      def initialize(status:, message:, duration_ms:, error: nil)
        @status = status
        @message = message
        @duration_ms = duration_ms
        @error = error
        if message.respond_to?(:cost)
          @cost = message.cost
          @input_tokens = message.input_tokens
          @output_tokens = message.output_tokens
        end
      end

      def completed? = @status == :completed
      def cancelled? = @status == :cancelled
      def errored?   = @status == :error
      def failed?    = @status == :failed

      # The trace-event-shaped payload. Status as String to keep dashboard
      # query compatibility with pre-refactor traces. tool_count optional.
      def trace_payload(tool_count: nil)
        payload = {
          status: @status.to_s,
          duration_ms: @duration_ms,
          cost: @cost,
          input_tokens: @input_tokens,
          output_tokens: @output_tokens
        }
        if @error
          payload[:error] = @error.class.name
          payload[:error_message] = @error.message.to_s.truncate(200)
        end
        payload[:tool_count] = tool_count if tool_count
        payload.compact
      end
    end

    def initialize(
      message:,
      subject:,
      query_text:,
      client:,
      session_for:,
      observer_factory:,
      system_context:,
      agent_name:,
      tracer:,
      on_finalized: ->(_msg, _ex) { },
      on_turn_finished: ->(_result) { },
      on_activity_tick: ->(_subject) { },
      empty_stream_retry_delay: DEFAULT_EMPTY_STREAM_RETRY_DELAY,
      final_exchange_timeout: DEFAULT_FINAL_EXCHANGE_TIMEOUT,
      final_exchange_retry_delay: DEFAULT_FINAL_EXCHANGE_RETRY_DELAY,
      error_fallback_content: ERROR_FALLBACK_CONTENT,
      error_feature: "opencode.turn"
    )
      @message = message
      @subject = subject
      @query_text = query_text
      @client = client
      @session_for = session_for
      @observer_factory = observer_factory
      @system_context = system_context
      @agent_name = agent_name
      @tracer = tracer
      @on_finalized = on_finalized
      @on_turn_finished = on_turn_finished
      @on_activity_tick = on_activity_tick
      @empty_stream_retry_delay = empty_stream_retry_delay
      @final_exchange_timeout = final_exchange_timeout
      @final_exchange_retry_delay = final_exchange_retry_delay
      @error_fallback_content = error_fallback_content
      @error_feature = error_feature
      @pre_turn_message_count = 0
    end

    def call
      @turn_started_at = monotonic_now
      emit("response.started", subject_id: @subject.id, message_id: @message.id)

      attempted_recreate = false
      begin
        run_turn
      rescue Opencode::SessionNotFoundError, Opencode::StaleSessionError
        raise if attempted_recreate
        @session_for.recreate!(@client)
        # Distinguish the recovery-with-resend path: if our original
        # async send was already accepted upstream, the recreate means
        # the upstream may now have orphan work it's still spending on.
        # The on-call engineer needs this distinction at 3am.
        emit("session.recreated_with_resend",
          session_id: @subject.opencode_session_id, subject_id: @subject.id)
        attempted_recreate = true
        retry
      end
    rescue StandardError => e
      handle_unexpected_error(e)
    end

    private

    # ---- Pipeline -------------------------------------------------------

    def run_turn
      session_id = @session_for.ensure!(@client)
      emit_session_created_if_new
      validate_session!(session_id)

      stream_result = stream_response(session_id)
      exchange = fetch_current_exchange(session_id)
      stream_result, exchange = wait_for_final_exchange_result(session_id, stream_result, exchange)
      last_assistant = exchange.reverse_each.detect { |m| m.dig(:info, :role) == "assistant" }

      @message.reload
      if @message.cancelled?
        save_cancelled_response(stream_result, last_assistant)
      elsif stream_result[:full_text].blank?
        recover_empty_stream(session_id, last_assistant, exchange)
      else
        finalize_response(stream_result, last_assistant, exchange)
      end
    end

    def validate_session!(session_id)
      messages = @client.get_messages(session_id)
      @pre_turn_message_count = messages.is_a?(Array) ? messages.size : 0
    end

    # `session.created` is emitted iff the session was *just* created by
    # the call to `ensure!` above. We ask the Session — which did the
    # work and knows the answer — instead of the subject's AR dirty
    # tracking, which would couple Turn to ActiveRecord-shaped records.
    def emit_session_created_if_new
      return unless @session_for.respond_to?(:just_created?)
      return unless @session_for.just_created?
      emit("session.created", session_id: @subject.opencode_session_id, subject_id: @subject.id)
    end

    # ---- Streaming ------------------------------------------------------

    def stream_response(session_id)
      reply = Opencode::Reply.new
      @reply = reply
      @observer_factory.call(@message).watch(reply)

      stream_started_at = monotonic_now
      last_activity_touch_at = stream_started_at
      first_token_at = nil
      event_count = 0
      prompt_attempted = false
      prompt_succeeded = false
      on_subscribed = lambda do
        # stream_events guarantees at-most-once invocation, but keep this
        # guard here as a second line of defense because an ambiguous prompt
        # response must never become a duplicate model turn.
        next false if prompt_attempted

        prompt_attempted = true
        @client.send_message_async(
          session_id, @query_text,
          agent: @agent_name.call(@subject),
          system: @system_context.call(@subject)
        )
        prompt_succeeded = true
      end

      begin
        release_active_record_connections
        # Throttled activity tick — fires on EVERY event including heartbeats
        # (via the stream_events :on_activity_tick kwarg). We need heartbeats
        # to count so that a user taking 30+ minutes to answer an ask-user
        # prompt keeps the container warm: the agent itself emits no events
        # while suspended, only the server's keep-alive does.
        #
        # The 5-minute throttle bounds DB write rate (one
        # update_column per tick, not per heartbeat). Reaper safety
        # is independent: the reaper's 30-minute idle threshold gives
        # 6× headroom over this throttle, so even if several ticks
        # miss the container survives.
        #
        # Wrapped in rescue so a transient DB blip on touch_activity
        # is observable but doesn't kill an otherwise-healthy in-flight
        # stream (heartbeats are advisory; next tick retries).
        activity_tick = ->(_event) {
          if (monotonic_now - last_activity_touch_at) >= ACTIVITY_TOUCH_INTERVAL
            begin
              @on_activity_tick.call(@subject)
              last_activity_touch_at = monotonic_now
            rescue StandardError => e
              Opencode::ErrorReporter.report(e, handled: true, severity: :warning,
                context: { feature: @error_feature, hook: :on_activity_tick })
            end
          end
        }

        @client.stream_events(
          session_id: session_id,
          reply: reply,
          on_activity_tick: activity_tick,
          on_subscribed: on_subscribed
        ) do |event|
          event_count += 1
          reply.apply(event)
          first_token_at ||= monotonic_now if reply.first_text_seen?
        end

        emit("stream.completed",
          duration_ms: elapsed_ms(stream_started_at),
          first_token_ms: first_token_at && ((first_token_at - stream_started_at) * 1000).round,
          event_count: event_count,
          tool_count: reply.respond_to?(:tool_count) ? reply.tool_count : nil)
      rescue Opencode::SessionNotFoundError
        raise
      rescue StandardError => e
        # Subscription rejection or prompt transport failure happened before
        # a turn was confirmed started. Recovering from the pre-turn exchange
        # could finalize stale text, and retrying an ambiguous POST could
        # duplicate spend, so surface the original failure to the outer error
        # path without reconnect/recovery.
        raise unless prompt_succeeded

        Opencode::ErrorReporter.report(e, handled: true, severity: :warning,
          context: { feature: @error_feature, error_class: e.class.name })
        emit("stream.interrupted",
          duration_ms: elapsed_ms(stream_started_at),
          event_count: event_count,
          error: e.class.name,
          error_message: e.message.to_s.truncate(200))
        attempt_stream_recovery(session_id, reply)
      end

      reply.result
    end

    def release_active_record_connections
      return unless defined?(ActiveRecord::Base)

      ActiveRecord::Base.connection_handler.clear_active_connections!
    end

    # If the session API is still reachable, fetch the current exchange
    # and rebaseline `reply` to whatever the server has. If the API is
    # also unreachable, keep whatever the reply accumulated before the
    # interruption.
    def attempt_stream_recovery(session_id, reply)
      exchange = fetch_current_exchange(session_id)
      last_msg = exchange.reverse_each.detect { |m| m.dig(:info, :role) == "assistant" }
      return unless last_msg

      recovered_parts = Opencode::ResponseParser.extract_interleaved_parts(last_msg)
      reply.replace_parts(recovered_parts) if recovered_parts.any?
    rescue StandardError
      # Session API also unreachable; keep whatever the reply has.
    end

    # ---- Finalize -------------------------------------------------------

    def finalize_response(stream_result, last_assistant, exchange)
      result = authoritative_result(stream_result, exchange)
      attrs = {
        content: result[:full_text],
        tool_calls_json: result[:tool_parts],
        parts_json: result[:parts_json],
        status: :completed
      }
      attrs[:reasoning] = result[:reasoning_text] if result[:reasoning_text].present?
      attrs.merge!(extract_cost(last_assistant)) if last_assistant

      unless @message.finalize!(**attrs)
        # finalize! returns false if message was cancelled/errored mid-flight.
        emit_turn_finished(status: :cancelled)
        return
      end

      # Callbacks run AFTER the system of record is durable. If a callback
      # raises (Redis flake on Turbo broadcast, ActiveJob enqueue hiccup
      # on title generation), the turn is still completed; the failure
      # is reported and isolated. Without this isolation a successful
      # turn could be flipped to :error by an unrelated infra hiccup.
      safe_callback(:on_finalized) { @on_finalized.call(@message, exchange) }
      emit_turn_finished(status: :completed)
    end

    def authoritative_result(stream_result, exchange)
      exchange_result = current_turn_result(exchange)
      return stream_result unless exchange_result
      return stream_result if exchange_result[:full_text].blank?

      merge_stream_only_parts(stream_result, exchange_result)
    end

    # The final session poll is authoritative for answer text and terminal
    # tool payloads, but OpenCode emits some events (`todo.updated`, and
    # whatever future bus events join Opencode::PartSource::STREAM_ONLY)
    # that never persist as message parts. Preserve those synthetic
    # stream parts across finalization so the refresh-rendered UI does
    # not drop the live state the user watched stream in.
    def merge_stream_only_parts(stream_result, exchange_result)
      stream_parts = Array(stream_result[:parts_json])
      return exchange_result unless stream_parts.any? { |part| Opencode::PartSource.stream_only?(part) }

      exchange_parts = Array(exchange_result[:parts_json]).dup
      merged = []

      stream_parts.each do |part|
        if Opencode::PartSource.stream_only?(part)
          merged << part
        elsif exchange_parts.any?
          merged << exchange_parts.shift
        end
      end

      merged.concat(exchange_parts)
      Opencode::Reply.distill(merged)
    end

    def wait_for_final_exchange_result(session_id, stream_result, exchange)
      result = authoritative_result(stream_result, exchange)
      sync_reply_from_result(result)
      return [ result, exchange ] if terminal_exchange_result?(result, exchange)
      return [ result, exchange ] unless exchange_indicates_more_work?(exchange)

      emit("response.waiting_for_final_text", subject_id: @subject.id, message_id: @message.id)
      deadline = monotonic_now + @final_exchange_timeout

      loop do
        return [ result, exchange ] if monotonic_now >= deadline

        sleep @final_exchange_retry_delay if @final_exchange_retry_delay.positive?
        exchange = fetch_current_exchange(session_id)
        result = authoritative_result(stream_result, exchange)
        sync_reply_from_result(result)
        return [ result, exchange ] if terminal_exchange_result?(result, exchange)
        return [ result, exchange ] unless exchange_indicates_more_work?(exchange)
      end
    end

    def sync_reply_from_result(result)
      return unless @reply.respond_to?(:sync_recovered_parts)
      return if result[:parts_json].blank?

      @reply.sync_recovered_parts(result[:parts_json])
    end

    def terminal_exchange_result?(result, exchange)
      return false if result[:full_text].blank?

      last_assistant = current_turn_assistant_messages(exchange).last
      return true unless last_assistant
      return false if assistant_in_progress?(last_assistant)

      assistant_finish(last_assistant) != "tool-calls"
    end

    def exchange_indicates_more_work?(exchange)
      last_assistant = current_turn_assistant_messages(exchange).last
      return false unless last_assistant

      assistant_finish(last_assistant) == "tool-calls" || assistant_in_progress?(last_assistant)
    end

    def assistant_finish(assistant_message)
      assistant_message.dig(:info, :finish).to_s
    end

    def assistant_in_progress?(assistant_message)
      time = assistant_message.dig(:info, :time)
      return false unless time.is_a?(Hash)
      return false unless time.key?(:created)

      time[:completed].blank?
    end

    def current_turn_result(exchange)
      parts = current_turn_assistant_messages(exchange).flat_map do |assistant_message|
        Opencode::ResponseParser.extract_interleaved_parts(assistant_message)
      end
      return nil if parts.empty?

      Opencode::Reply.distill(parts)
    end

    def current_turn_assistant_messages(exchange)
      Array(exchange).select { |message| message.dig(:info, :role) == "assistant" }
    end

    def save_cancelled_response(stream_result, last_assistant)
      content = stream_result[:full_text].presence || "Response was stopped."
      attrs = {
        content: content,
        tool_calls_json: stream_result[:tool_parts],
        parts_json: stream_result[:parts_json]
      }
      attrs[:reasoning] = stream_result[:reasoning_text] if stream_result[:reasoning_text].present?
      attrs.merge!(extract_cost(last_assistant)) if last_assistant
      @message.update!(**attrs)
      emit_turn_finished(status: :cancelled)
    end

    # ---- Empty-stream recovery ------------------------------------------

    def recover_empty_stream(session_id, last_assistant, exchange)
      recovered = recover_from_exchange(last_assistant)

      unless recovered
        sleep @empty_stream_retry_delay if @empty_stream_retry_delay.positive?
        exchange = fetch_current_exchange(session_id)
        last_assistant = exchange.reverse_each.detect { |m| m.dig(:info, :role) == "assistant" }
        recovered = recover_from_exchange(last_assistant)
      end

      if recovered
        emit("response.recovered_from_exchange")
        finalize_response(recovered, last_assistant, exchange)
      elsif detect_upstream_error(last_assistant)
        mark_error(reason: "upstream_llm_error")
      else
        mark_error(reason: "empty_stream")
      end
    end

    def recover_from_exchange(assistant_message)
      return nil unless assistant_message
      parts_json = Opencode::ResponseParser.extract_interleaved_parts(assistant_message)
      return nil if parts_json.empty?
      result = Opencode::Reply.distill(parts_json)
      return nil if result[:full_text].blank?

      result
    end

    def detect_upstream_error(assistant_message)
      return nil unless assistant_message
      error = Opencode::ResponseParser.extract_error(assistant_message)
      return nil unless error

      emit("response.upstream_error",
        error_name: error[:name],
        error_message: error[:message],
        status_code: error[:status_code],
        provider_url: error[:url])

      Opencode::ErrorReporter.report(
        Opencode::Error.new("Upstream LLM error: #{error[:name]} - #{error[:message]}"),
        handled: true,
        severity: :error,
        context: { feature: @error_feature, **error }
      )

      error
    end

    # ---- Error paths ----------------------------------------------------

    # Both error paths transition the message to :error through the
    # CAS-safe Message#error! contract — a concurrent cancel that already
    # moved the row out of :pending wins, and the canceller's terminal
    # state survives. emit_turn_finished re-reads the persisted state
    # (Result.message is reloaded) so callbacks receive the actual
    # current state, not the state we wished we wrote.

    def handle_unexpected_error(e)
      Opencode::ErrorReporter.report(e, handled: true, severity: :error,
        context: { feature: @error_feature, message_id: @message.id, error_class: e.class.name })
      @message.error!(@error_fallback_content)
      emit_turn_finished(status: :failed, error: e)
    end

    def mark_error(reason:)
      emit("response.error", reason: reason, message_id: @message.id, subject_id: @subject.id)
      @message.error!(@error_fallback_content)
      emit_turn_finished(status: :error)
    end

    # ---- Trace + callback helpers --------------------------------------

    def emit(name, **payload)
      @tracer.call(name, **payload)
    end

    def emit_turn_finished(status:, error: nil)
      @message.reload if @message.respond_to?(:reload)
      result = Result.new(
        status: status,
        message: @message,
        duration_ms: elapsed_ms(@turn_started_at),
        error: error
      )

      safe_callback(:on_turn_finished) { @on_turn_finished.call(result) }

      tool_count = @message.respond_to?(:tool_calls_json) ? @message.tool_calls_json&.size.to_i : nil
      emit("turn.finished", **result.trace_payload(tool_count: tool_count))
    end

    # Run a callback, report any exception, but keep the turn in its
    # current durable state. Side-effect callbacks (broadcast, artifact
    # collection, title enqueueing) are not allowed to overwrite
    # :completed → :error after the message is already persisted.
    def safe_callback(name)
      yield
    rescue StandardError => e
      Opencode::ErrorReporter.report(e, handled: true, severity: :warning,
        context: { feature: @error_feature, callback: name, message_id: @message.id, error_class: e.class.name })
      emit("callback.error", callback: name.to_s, error_class: e.class.name)
    end

    # ---- Exchange + cost helpers ---------------------------------------

    def fetch_current_exchange(session_id)
      messages = @client.get_messages(session_id)
      return [] unless messages.is_a?(Array) && messages.any?

      search_start_idx = [ @pre_turn_message_count.to_i, messages.length ].min
      last_user_idx = nil
      (messages.length - 1).downto(search_start_idx) do |idx|
        message = messages[idx]
        if message.dig(:info, :role) == "user" && user_message_text(message) == @query_text.to_s
          last_user_idx = idx
          break
        end
      end
      return [] unless last_user_idx
      messages[(last_user_idx + 1)..]
    rescue Opencode::Error => e
      Opencode::ErrorReporter.report(e, handled: true, severity: :warning,
        context: { feature: @error_feature, action: "fetch_current_exchange", session_id: session_id })
      []
    end

    def user_message_text(message)
      Opencode::ResponseParser.extract_text(message).to_s
    end

    def extract_cost(assistant_msg)
      cost = Opencode::ResponseParser.extract_cost(assistant_msg)
      cache = Opencode::ResponseParser.extract_cache_tokens(assistant_msg)
      tokens = Opencode::ResponseParser.extract_tokens(assistant_msg) || {}
      {
        cost: cost,
        input_tokens: tokens[:input],
        output_tokens: tokens[:output],
        cache_read_tokens: cache[:cache_read],
        cache_write_tokens: cache[:cache_write]
      }.compact
    end

    # ---- Time helpers ---------------------------------------------------

    def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    def elapsed_ms(t) = ((monotonic_now - t) * 1000).round
  end
end
