# frozen_string_literal: true

module Opencode
  # Owns the lifecycle of an OpenCode session against a domain record.
  #
  # Consolidates a lifecycle that's easy to get subtly wrong: a host
  # with N conversational products tends to grow N near-identical
  # session-management code paths that drift on the details (which
  # one took a row-level lock? which one swallowed teardown errors?).
  # Single PORO, one place to change, no shotgun surgery when the
  # protocol evolves.
  #
  # Usage:
  #
  #   service = Opencode::Session.new(
  #     conversation,
  #     permissions_for: ->(record) { permission_rules_for(record) },
  #     on_error: ->(e, **opts) { Rails.error.report(e, **opts) }   # optional
  #   )
  #   session_id = service.ensure!(client)   # idempotent create-or-resolve
  #   service.recreate!(client)              # always create fresh
  #   service.abort!(client)                 # best-effort upstream abort
  #
  # The permissions_for: callable receives the record at mint! time and
  # returns the permissions array for client.create_session. Per-product
  # scoping (e.g. a record's workspace_key or tenant_id branching) lives
  # in the caller's lambda, not in this class — that keeps Session free
  # of any reference to permission-building helpers.
  #
  # The on_error: callable is invoked when abort! catches an
  # Opencode::Error during teardown. Callers wire their own observability
  # (Rails.error.report, OpenTelemetry, Sentry, custom logging) here.
  # Defaults to nil — silently swallowing teardown errors, which matches
  # the pre-inversion behaviour. Substrate has no opinion about how the
  # host reports.
  #
  # The record must respond to:
  #   - #title (String) — passed as session title
  #   - #opencode_session_id / #opencode_session_id= — string column
  #   - #with_lock(&block) — ActiveRecord row-level lock
  #   - #update! / #reload — standard ActiveRecord
  #   - #id — for error reporting context
  class Session
    def initialize(record, permissions_for:, on_error: nil)
      @record = record
      @permissions_for = permissions_for
      @on_error = on_error
      @just_created = false
    end

    # True iff the most recent ensure!/recreate! actually created a
    # fresh upstream session (vs resolving to an existing id).
    #
    # Exists so consumers can distinguish "we just minted this" from
    # "we found an existing one" without poking at ActiveRecord dirty
    # tracking on the record. The right object to ask is the object
    # that did the work; that's this one.
    def just_created?
      @just_created
    end

    # Returns the session id for the record, creating an OpenCode session
    # if none exists yet. Idempotent. Race-safe via row-level locking and
    # double-check shortcuts that avoid the lock entirely when an id is
    # already persisted.
    def ensure!(client)
      @just_created = false
      return @record.opencode_session_id if @record.opencode_session_id.present?

      @record.with_lock do
        # Double-check inside the lock: another worker may have set the
        # id between our first read and acquiring the lock.
        return @record.opencode_session_id if @record.opencode_session_id.present?

        mint!(client)
      end
    rescue ActiveRecord::RecordNotUnique
      # Two workers raced past the unique-index gate. The loser reloads
      # to pick up the winner's id. The winner is the one that
      # just_created?; the loser sees @just_created = false.
      @record.reload
      @record.opencode_session_id
    end

    # Always creates a fresh session and overwrites the persisted id.
    # Used by Opencode::Turn recovery when the upstream session has gone
    # stale (StaleSessionError / SessionNotFoundError).
    #
    # Race semantics: two concurrent recreate! callers serialize through
    # with_lock; the first mints, the second observes the freshly-minted
    # id (different from its own pre-lock snapshot) and returns that
    # rather than minting again. Both callers converge on one upstream
    # session — no orphan leak.
    def recreate!(client)
      @just_created = false
      pre_lock_id = @record.opencode_session_id

      @record.with_lock do
        # If another recreate! caller minted while we were waiting for
        # the lock, the id changed under us. Treat their fresh mint as
        # fresh enough for us too — recreate! returns "a session that's
        # newer than what I saw at method entry", not "specifically my
        # own mint".
        current_id = @record.opencode_session_id
        if current_id.present? && current_id != pre_lock_id
          return current_id
        end

        mint!(client)
      end
    end

    # Best-effort upstream abort. Swallows Opencode::Error so callers
    # never have to wrap this in a rescue — aborts run inside cleanup
    # paths where re-raising would mask the real cause of teardown.
    def abort!(client)
      return unless @record.opencode_session_id.present?

      client.abort_session(@record.opencode_session_id)
    rescue Opencode::Error => e
      @on_error&.call(e, action: "abort_session", record_id: @record.id)
    end

    private

    # The atomic create-and-persist unit shared by ensure! and recreate!.
    #
    # One operation, two failure modes:
    #   - client.create_session raises    -> nothing to clean up, re-raise
    #   - update! raises RecordInvalid    -> upstream session exists,
    #                                        delete it before re-raising
    #                                        so we never leak orphans
    #
    # Sets @just_created = true on success; callers reset to false at
    # method entry so a no-op call (existing id) reports false correctly.
    def mint!(client)
      session_id = nil

      begin
        result = client.create_session(title: @record.title, permissions: @permissions_for.call(@record))
        session_id = extract_session_id(result)
        @record.update!(opencode_session_id: session_id)
        @just_created = true
        session_id
      rescue ActiveRecord::RecordInvalid
        safely_delete(client, session_id) if session_id
        raise
      end
    end

    # OpenCode HTTP responses use symbol keys when parsed via JSON.parse
    # with symbolize_names: true (Opencode::Client) but mocks/stubs in
    # tests often produce string-keyed hashes. Accept both.
    def extract_session_id(result)
      result[:id] || result["id"]
    end

    def safely_delete(client, session_id)
      client.delete_session(session_id)
    rescue Opencode::Error
      # Best-effort cleanup; the orphan may be gone already or the
      # upstream is unavailable. Either way, we already have a real
      # error to raise.
    end
  end
end
