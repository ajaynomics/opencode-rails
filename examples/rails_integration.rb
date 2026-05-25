# frozen_string_literal: true

# examples/rails_integration.rb
#
# Production-shaped integration of opencode-rails into a Rails app.
# This file is NOT loaded by the gem at runtime — it's a reference
# blueprint. Drop the patterns into your app and adapt to your
# domain (Conversation/Message/User naming, ActiveStorage attachments,
# Turbo broadcasts).
#
# The pattern is extracted from a production Rails app where it ships
# multiple OpenCode-backed conversational products. It works for any
# host that has:
#
#   - A "conversation" AR row that owns an `opencode_session_id:string`
#     column and a has_many :messages association.
#   - A "message" AR row with `role:string, status:string,
#     parts_json:jsonb, content:text` (plus whatever fields your domain needs).
#   - SolidQueue (or Sidekiq, GoodJob) for the background job.
#   - Turbo for live streaming UX (optional but assumed).
#
# What each section demonstrates:
#
#   1. Initializer: route Instrumentation + ErrorReporter adapters
#      to ActiveSupport::Notifications and Rails.error.report.
#   2. Job: orchestrate one turn with Opencode::Session + Opencode::Turn.
#   3. ReplyObserver: bridge Reply state to Turbo Stream broadcasts.
#   4. Permissions builder: per-product session permission rules.
#
# Tested patterns. Every line below has been exercised in production.
# Copy what you need; adapt to your domain.

# ----------------------------------------------------------------------
# 1. config/initializers/opencode.rb
# ----------------------------------------------------------------------
#
# Wire the two adapters opencode-ruby + opencode-rails ship with. The
# gems are silent by default; the host explicitly opts into routing
# events to its observability stack.

Rails.application.config.to_prepare do
  # opencode-ruby: every HTTP request, SSE event lifecycle, recovery
  # path flows through this adapter as an ActiveSupport::Notifications
  # event. Subscribers in this app pick it up via
  # `ActiveSupport::Notifications.subscribe("opencode.*", ...)`.
  Opencode::Instrumentation.adapter = ->(name, payload, &block) {
    ActiveSupport::Notifications.instrument(name, payload, &block)
  }

  # opencode-rails: swallowed errors (Session abort failure, Turn
  # callback exception, MessageArtifacts transform error) flow through
  # this adapter. Wire your Honeybadger / Sentry / Rails.error reporter
  # here.
  Opencode::ErrorReporter.adapter = ->(error, **opts) {
    Rails.error.report(error, **opts)
  }
end

# ----------------------------------------------------------------------
# 2. app/jobs/generate_response_job.rb
# ----------------------------------------------------------------------
#
# One job per assistant message. Idempotent on the message row: if
# the message is already :completed or :error, the job is a no-op.
# The Turn class handles all the orchestration; this job is mostly
# wiring + error fallback.

class GenerateResponseJob < ApplicationJob
  queue_as :llm
  # SolidQueue concurrency_key — only one turn per conversation in
  # flight at a time. Without this, a user sending two messages back-
  # to-back can race two turns through the same OpenCode session.
  limits_concurrency to: 1, key: ->(message) { "GenerateResponseJob/#{message.conversation_id}" }

  def perform(assistant_message)
    return if assistant_message.terminal?  # idempotent

    conversation = assistant_message.conversation
    user_message = conversation.messages.where(role: :user).order(:created_at).last
    client       = Opencode::Client.new(base_url: ENV.fetch("OPENCODE_URL"))

    # Session: AR-coupled, row-locked, idempotent. ensure! creates the
    # OpenCode session if conversation.opencode_session_id is blank;
    # returns the existing id otherwise.
    session = Opencode::Session.new(
      conversation,
      permissions_for: ->(record) { permission_rules_for(record) },
      on_error:        ->(e, **opts) { Opencode::ErrorReporter.report(e, **opts) }
    )

    # Turn: the orchestrator. Drives send -> stream -> recover ->
    # finalize. Pass it the host's ReplyObserver factory so the gem's
    # Reply state machine can bridge to your Turbo broadcasts.
    Opencode::Turn.new(
      message:        assistant_message,
      subject:        conversation,
      query_text:     user_message.content,
      client:         client,
      session_for:    ->(*) { session },
      observer_factory: ->(message) { ReplyStream.new(message: message) },
      system_context: build_system_context(conversation),
      agent_name:     "default",
      tracer:         Opencode::Tracer.new(prefix: "opencode."),
      on_turn_finished: ->(result) {
        Rails.logger.info("turn finished status=#{result.status} cost=#{result.cost}")
      }
    ).call
  rescue StandardError => e
    Opencode::ErrorReporter.report(e, severity: :error,
      context: { message_id: assistant_message.id, conversation_id: conversation.id })
    assistant_message.update!(status: :error, content: "Sorry, something went wrong.")
  end

  private

  def permission_rules_for(conversation)
    # Per-product permissions. The shape mirrors what
    # opencode-ruby's Client#create_session expects in `permissions:`.
    [
      { type: "edit", action: "allow", path: "data/sandbox/#{conversation.id}/" },
      { type: "edit", action: "deny",  path: "*" }  # default deny outside sandbox
    ]
  end

  def build_system_context(conversation)
    # System prompt context the agent gets. Your app probably already
    # has helpers for this; the gem doesn't impose a shape.
    {
      user_name:        conversation.user.name,
      conversation_id:  conversation.id,
      sandbox_path:     "/sandbox/#{conversation.id}"
    }
  end
end

# ----------------------------------------------------------------------
# 3. app/services/reply_stream.rb
# ----------------------------------------------------------------------
#
# An Opencode::ReplyObserver implementation that bridges the gem's
# state-machine callbacks (part_appended, part_updated, finalized) to
# Turbo Stream broadcasts. The gem ships the protocol; the host owns
# the rendering.
#
# This is one of three places hosts customize: the renderer of a
# tool-call part. The other two are permission_rules_for and
# build_system_context above.

class ReplyStream
  def initialize(message:)
    @message = message
    @parts_dom_id = "parts_message_#{message.id}"
  end

  # Called every time a new part shows up in the reply.
  def on_part_appended(part)
    Turbo::StreamsChannel.broadcast_append_to(
      @message.conversation,
      target: @parts_dom_id,
      partial: "messages/part",
      locals: { part: part, message: @message }
    )
  end

  # Called when an existing part's content grows (text/reasoning
  # deltas, tool state changes).
  def on_part_updated(part, _index)
    Turbo::StreamsChannel.broadcast_update_to(
      @message.conversation,
      target: "part_#{part['id']}_message_#{@message.id}",
      partial: "messages/part",
      locals: { part: part, message: @message }
    )
  end

  # Called when the turn finalizes. Use this to swap "Thinking…"
  # placeholders, update message status indicators, etc.
  def on_finalized(reply_result)
    Turbo::StreamsChannel.broadcast_update_to(
      @message.conversation,
      target: "message_#{@message.id}_status",
      partial: "messages/status",
      locals: { message: @message, result: reply_result }
    )
  end

  # Optional: called when the gem catches an exception mid-stream and
  # has done its own recovery (recreated session, retried, etc.). Use
  # this for a brief transient banner in the UI.
  def on_error(message, severity:)
    Turbo::StreamsChannel.broadcast_replace_to(
      @message.conversation,
      target: "message_#{@message.id}_status",
      html: %(<div class="banner banner--warn">#{message}</div>)
    )
  end
end

# ----------------------------------------------------------------------
# That's it. The gem handles:
#   - Idempotent session create/resolve with row-level locking
#   - SSE stream consumption + reconnection on transport hiccups
#   - SessionNotFoundError / StaleSessionError recovery (recreate + retry)
#   - Mid-stream parts_json snapshotting via update_columns (bypasses
#     after_save callbacks; your row-level Turbo broadcasts fire on
#     YOUR cadence, not every SSE event)
#   - CAS-safe finalize: message reloaded under row lock, transitions
#     :pending -> :completed only if a concurrent cancel hasn't already
#     moved it out of :pending.
#   - Cost + token extraction from the final exchange
#   - Artifact pipeline (MessageArtifacts.attach_from) with optional
#     transforms (host-rendered HTML, JSON-to-PDF, etc.)
#
# Your job is the wiring. About 80 lines of Ruby gets you a production-
# grade chat agent.
