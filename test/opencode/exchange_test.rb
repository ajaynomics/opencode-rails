# frozen_string_literal: true

require "test_helper"

# Smoke test for Opencode::Exchange — verifies it instantiates, can be
# given empty input, and exposes the public surface (`tool_artifacts`).
# Deeper behavioral tests live in the host application
# (test/lib/opencode/rails/exchange_test.rb) where AR fixtures, real
# wire shapes, and the apply-patch event stream are available.
class Opencode::ExchangeTest < Minitest::Test
  def test_initializes_with_empty_messages
    exchange = Opencode::Exchange.new([])
    assert_equal [], exchange.tool_artifacts
  end

  def test_initializes_with_nil_messages_via_array_coerce
    exchange = Opencode::Exchange.new(nil)
    assert_equal [], exchange.tool_artifacts
  end

  def test_tool_artifacts_supports_exclude_kwarg
    exchange = Opencode::Exchange.new([])
    # Should not raise when given an exclude list against empty input.
    assert_equal [], exchange.tool_artifacts(exclude: %w[notes.md])
  end
end
