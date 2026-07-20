# opencode-rails

Production-grade [OpenCode](https://opencode.ai) integration for Rails apps. Layers an ActiveRecord-aware session lifecycle, a turn orchestrator, an artifact pipeline, and a sandbox model on top of the wire-level client in [`opencode-ruby`](https://github.com/ajaynomics/opencode-ruby).

> **Alpha software.** API will change before 1.0. Pin to a specific version.

## Why this gem exists

`opencode-ruby` gives you a clean Net::HTTP + SSE client. To turn it into something a Rails app can ship, you need:

1. **Session lifecycle** — idempotent create-or-resolve with row-level locking so concurrent jobs don't double-mint sessions; recreation for stale-session recovery; best-effort upstream abort on teardown.
2. **Turn orchestration** — drive `send_message_async`, stream events into `Opencode::Reply`, recover from `SessionNotFoundError` / `StaleSessionError` by recreating + retrying, fetch the final exchange for cost/artifact extraction, finalize the persisted message via CAS against `:pending`.
3. **Mid-stream snapshot** — `update_columns` writes to bypass AR callbacks so app-level Turbo broadcasts fire on rate-limited intervals, not every SSE event.
4. **Artifact pipeline** — extract files written by the agent (via the `write` tool's metadata, or by reading from a sandbox path), attach them to the assistant message via ActiveStorage, transform host-rendered artifacts (flight results HTML, etc.) before persisting.

`opencode-rails` ships these as named, single-responsibility objects so you wire them up instead of re-implementing them.

## Install

After both alpha8 gems are confirmed on RubyGems, pin the lockstep tuple:

```ruby
# Gemfile
gem "opencode-ruby", "= 0.0.1.alpha8" # wire client + Reply state machine
gem "opencode-rails", "= 0.0.1.alpha8"
```

Until publication is verified, validate this candidate checkout against the
exact `opencode-ruby` source it was tested with:

```ruby
# Gemfile
gem "opencode-ruby",
  git: "https://github.com/ajaynomics/opencode-ruby.git",
  ref: "9277646a4bb2cf25a8384ffc140b154f49ea5766"

gem "opencode-rails",
  path: "../opencode-rails"
```

```bash
bundle install
```

Runtime deps: `activerecord`, `activestorage`, `activesupport` (>= 7.1). Depends on `opencode-ruby` for the underlying HTTP/SSE primitives.

During the alpha series both gems are pinned in lockstep. Version 0.0.1.alpha8
retains the subscribe-ready-before-prompt transport contract and reconnects an
accepted turn without posting its prompt again, while hardening SSE framing.

`opencode-rails` 0.0.1.alpha8 is a release candidate and is not yet confirmed
published on RubyGems. The `release.yml` workflow is prepared for RubyGems
trusted publishing, but the gem's trusted publisher must be registered and
verified for that workflow and its `release` environment. Until the registry
result is verified, pushing a `v*` tag does not guarantee publication. Trusted
publishing does not require a long-lived RubyGems API key.

## Quickstart

```ruby
# config/initializers/opencode.rb
Opencode::Instrumentation.adapter = ->(name, payload, &blk) {
  ActiveSupport::Notifications.instrument(name, payload, &blk)
}
Opencode::ErrorReporter.adapter = ->(error, **opts) {
  Rails.error.report(error, **opts) if Rails.respond_to?(:error)
}
```

```ruby
# app/services/noop_reply_observer.rb
#
# Turn requires an observer factory even when the app does not need live
# partial rendering. For a streaming UI, replace this with an observer that
# persists/broadcasts selected ReplyObserver callbacks (and throttle writes).
class NoopReplyObserver
  include Opencode::ReplyObserver

  def watch(reply)
    reply.add_observer(self)
    self
  end
end
```

```ruby
# app/jobs/generate_response_job.rb
class GenerateResponseJob < ApplicationJob
  def perform(assistant_message)
    conversation = assistant_message.conversation
    user_message = conversation.messages.where(role: :user).last
    client       = Opencode::Client.new(base_url: ENV.fetch("OPENCODE_URL"))

    session = Opencode::Session.new(
      conversation,
      permissions_for: ->(record) { permission_rules_for(record) },
      on_error:        ->(e, **opts) { Opencode::ErrorReporter.report(e, **opts) }
    )

    Opencode::Turn.new(
      message:        assistant_message,
      subject:        conversation,
      query_text:     user_message.content,
      client:         client,
      session_for:    session,
      observer_factory: ->(_message) { NoopReplyObserver.new },
      system_context: ->(record) { "You are assisting with #{record.title}." },
      agent_name:     ->(_record) { ENV.fetch("OPENCODE_AGENT", "build") },
      tracer:         ->(name, **payload) {
        ActiveSupport::Notifications.instrument("assistant.#{name}", payload)
      },
      on_turn_finished: ->(result) {
        # result.status   #=> :completed | :cancelled | :error | :failed
        # result.message  #=> the AR row (reloaded)
        # result.duration_ms
      }
    ).call
  end

  private

  def permission_rules_for(conversation)
    [
      { type: "edit", action: "allow", path: "data/sandbox/#{conversation.id}/" }
    ]
  end
end
```

The host record (here `conversation`) must respond to `#title`,
`#opencode_session_id`, `#opencode_session_id=`, `#with_lock(&block)`,
`#update!`, `#reload`, and `#id`. The assistant message must respond to `#id`,
`#reload`, `#cancelled?`, `#finalize!(**attrs)`, `#update!(**attrs)`, and
`#error!(content)`. A non-no-op observer may impose additional record methods
for its own live snapshots.

`Opencode::Turn` is an internal, alpha-stage composition seam. Its keyword
constructor is intentionally explicit and may change before 1.0, so keep this
wiring in one host service/job and keep the gem source pinned exactly.

## What you get

| Constant | Role |
|---|---|
| `Opencode::Session` | Idempotent ensure!/recreate!/abort! with row-level locking |
| `Opencode::Turn` | End-to-end orchestrator: ensure session → send → stream → recover → finalize |
| `Opencode::Exchange` | Domain object over a turn's message array; owns artifact extraction |
| `Opencode::Artifact` | Value object: filename + bytes + content_type + trust metadata |
| `Opencode::MessageArtifacts` | Idempotent attachment pipeline (ActiveStorage-aware, transform-applying) |
| `Opencode::Sandbox` | Reads written files from disk, returns Artifact list |
| `Opencode::SandboxFile` | Single-file value: pathname → bytes/content-type/identity Artifact |
| `Opencode::Transform` | Base class for content-rewriting transforms (e.g. host-rendered HTML) |
| `Opencode::Impostor` | ActiveStorage download/upload helper that round-trips bytes |
| `Opencode::UploadedFilesPrompt` | Builds the user-prompt prefix listing uploaded files |
| `Opencode::ToolDisplay` | View-model converting tool-call hashes to Turbo-friendly props |
| `Opencode::ErrorReporter` | Pluggable adapter for routing swallowed errors |

Plus everything from `opencode-ruby`: `Client`, `Reply`, `ReplyObserver`, `Tracer`, `Prompts`, `ResponseParser`, `ToolPart`, `PartSource`, `Todo`, `Instrumentation`, the error hierarchy.

## Instrumentation + error reporting

The gem emits events through `Opencode::Instrumentation.instrument(name, payload, &blk)` and reports swallowed errors through `Opencode::ErrorReporter.report(error, **opts)`. Both are no-ops by default. Wire your host's emitter / reporter in an initializer (see Quickstart above).

Events emitted (non-exhaustive):

- `opencode.turn.started`, `opencode.turn.finished`
- `opencode.stream.completed`, `opencode.stream.interrupted`
- `opencode.session.created`, `opencode.session.recreated`
- `opencode.apply_patch.artifacts_dropped`
- `opencode.response.upstream_error`

Subscribe via `ActiveSupport::Notifications.subscribe("opencode.*")` once you've wired the adapter.

## Position

`opencode-rails` is for Rails apps that want production-grade OpenCode streaming without reimplementing the orchestration boilerplate. If you want only the wire client, use `opencode-ruby` directly. If you want every endpoint with generated types, use [`opencode_client`](https://rubygems.org/gems/opencode_client) (Eric Guo's auto-generated gem).

## License

MIT. See [LICENSE](LICENSE).
