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

After both alpha9 gems are confirmed on RubyGems, pin the lockstep tuple:

```ruby
# Gemfile
gem "opencode-ruby", "= 0.0.1.alpha9" # wire client + Reply state machine
gem "opencode-rails", "= 0.0.1.alpha9"
```

Until publication is verified, validate this candidate checkout against the
exact `opencode-ruby` source it was tested with:

```ruby
# Gemfile
gem "opencode-ruby",
  git: "https://github.com/ajaynomics/opencode-ruby.git",
  ref: "65a44ca1502926d533e6b4b6692779fa39740218"

gem "opencode-rails",
  path: "../opencode-rails"
```

```bash
bundle install
```

Runtime deps: `activerecord`, `activestorage`, `activesupport` (>= 7.1), and
`marcel`. Depends on `opencode-ruby` for the underlying HTTP/SSE primitives.

`UploadedFilesPrompt` anchors upload writes through `/proc/self/fd` or
`/dev/fd` to prevent sandbox-root path swaps. Hosts using upload copying must
provide one of those traversable descriptor filesystems; unsupported platforms
fail closed before writing.

During the alpha series both gems are pinned in lockstep. Version 0.0.1.alpha9
retains the subscribe-ready-before-prompt transport contract and reconnects an
accepted turn without posting its prompt again, while hardening SSE framing.

The unrepaired `opencode-ruby` 0.0.1.alpha8 package was yanked, and
`opencode-rails` alpha8 was never published.
`opencode-rails` 0.0.1.alpha9 is a release candidate and is not yet confirmed
published on RubyGems. Because the gem has no RubyGems entry yet, create a
pending trusted publisher for gem `opencode-rails`, repository owner
`ajaynomics`, repository `opencode-rails`, workflow `release.yml`, and
environment `release`. RubyGems converts it to a normal trusted publisher after
the first successful push. The workflow also refuses to publish until the
RubyGems `opencode-ruby` alpha9 package exists and installs and loads with the
locally built Rails package. Until the registry result is verified, pushing a
`v*` tag does not guarantee publication. Trusted publishing does not require a
long-lived RubyGems API key.

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
  def perform(assistant_message, user_message)
    conversation = assistant_message.conversation
    unless user_message.conversation_id == conversation.id
      raise ArgumentError, "User and assistant messages must belong to the same conversation"
    end
    working_directory = File.realpath(ENV.fetch("OPENCODE_WORKING_DIRECTORY"))
    client = Opencode::Client.new(
      base_url: ENV.fetch("OPENCODE_URL"),
      directory: working_directory
    )

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

  def permission_rules_for(_conversation)
    [
      { permission: "*", pattern: "*", action: "deny" }
    ]
  end
end
```

Run the OpenCode server with `OPENCODE_DISABLE_PROJECT_CONFIG=1`. OpenCode loads
project configuration, plugins, and instructions while opening a directory,
before session permissions exist; the wildcard deny rule cannot constrain that
bootstrap. Point `OPENCODE_WORKING_DIRECTORY` at a pre-provisioned directory
mounted at the same absolute path in Rails and OpenCode. Treat the server's
global configuration, plugins, and instructions as privileged administrator
code and verify the setting against the deployed OpenCode version.

This quickstart intentionally grants no filesystem tools: OpenCode permissions
alone are not an OS sandbox. Add product-specific allows only when the OpenCode
process also has an independent container or operating-system boundary.

`Opencode::Session` applies permissions only when it creates a session. Before
deploying a directory or permission-policy change, recreate persisted sessions
with a client scoped to the new directory; an existing session ID does not
prove that the new policy was applied.

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

The wire client emits `opencode.request` and artifact extraction emits
`opencode.apply_patch.artifacts_dropped` through `Opencode::Instrumentation`.
Turn events flow through the injected tracer; with the Quickstart's
`assistant.` prefix they include:

- `assistant.response.started`, `assistant.turn.finished`
- `assistant.stream.completed`, `assistant.stream.interrupted`
- `assistant.session.created`, `assistant.session.recreated_with_resend`
- `assistant.response.upstream_error`

Swallowed errors flow through `Opencode::ErrorReporter.report(error, **opts)`.
Instrumentation and error reporting are no-ops until the host wires adapters.

## Position

`opencode-rails` is for Rails apps that want production-grade OpenCode streaming without reimplementing the orchestration boilerplate. If you want only the wire client, use `opencode-ruby` directly. If you want every endpoint with generated types, use [`opencode_client`](https://rubygems.org/gems/opencode_client) (Eric Guo's auto-generated gem).

## License

MIT. See [LICENSE](LICENSE).
