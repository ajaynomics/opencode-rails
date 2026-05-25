# frozen_string_literal: true

require "test_helper"

# Contract smoke for Opencode::Session. Behavioral coverage (idempotent
# ensure!/recreate!/abort! with row-level locking, race-safety,
# permissions_for callable handoff) lives in the host application
# where AR fixtures + a real ActiveRecord row exist.
class Opencode::SessionTest < Minitest::Test
  def test_initialize_takes_record_and_two_keyword_callables
    params = Opencode::Session.instance_method(:initialize).parameters

    assert_includes params, [ :req, :record ],
      "Session must take a positional record (an AR row with #with_lock, #title, etc.)"
    assert_includes params, [ :keyreq, :permissions_for ],
      "Session must require a permissions_for: callable (host-injected per-product permissions)"
    assert_includes params, [ :key, :on_error ],
      "Session must accept an optional on_error: callable for adapter-style error reporting"
  end

  def test_public_api_is_ensure_recreate_abort_just_created
    methods = Opencode::Session.instance_methods(false).sort
    assert_equal %i[abort! ensure! just_created? recreate!].sort, methods.sort,
      "Session's public surface should be exactly: ensure!/recreate!/abort!/just_created?. " \
      "Found: #{methods.inspect}"
  end
end
