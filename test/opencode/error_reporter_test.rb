# frozen_string_literal: true

require "test_helper"

class Opencode::ErrorReporterTest < Minitest::Test
  def setup
    @original_adapter = Opencode::ErrorReporter.adapter
    Opencode::ErrorReporter.adapter = nil
  end

  def teardown
    Opencode::ErrorReporter.adapter = @original_adapter
  end

  def test_report_is_no_op_without_adapter
    # Must not raise, must return nil.
    result = Opencode::ErrorReporter.report(StandardError.new("boom"))
    assert_nil result
  end

  def test_report_forwards_to_adapter
    captured = []
    Opencode::ErrorReporter.adapter = ->(error, **opts) {
      captured << [error, opts]
      :sentinel
    }

    err = ArgumentError.new("bad arg")
    result = Opencode::ErrorReporter.report(err, severity: :error, context: { foo: 1 })

    assert_equal :sentinel, result
    assert_equal 1, captured.length
    captured_error, captured_opts = captured.first
    assert_same err, captured_error
    assert_equal :error, captured_opts[:severity]
    assert_equal({ foo: 1 }, captured_opts[:context])
  end

  def test_report_accepts_no_keyword_args
    invoked = false
    Opencode::ErrorReporter.adapter = ->(error, **opts) {
      invoked = true
      assert_empty opts
      refute_nil error
    }

    Opencode::ErrorReporter.report(RuntimeError.new("kaboom"))
    assert invoked, "Adapter should be invoked even with no kwargs"
  end

  def test_adapter_exceptions_propagate
    # If the host's adapter itself raises (Honeybadger HTTP failure,
    # Sentry quota error, etc.) the gem must propagate — silently
    # swallowing the adapter's own errors would hide an outage from
    # operators who think their error tracker is healthy.
    Opencode::ErrorReporter.adapter = ->(_error, **_opts) {
      raise StandardError, "adapter blew up"
    }

    raised = assert_raises(StandardError) do
      Opencode::ErrorReporter.report(RuntimeError.new("original"))
    end
    assert_equal "adapter blew up", raised.message
  end

  def test_report_returns_adapter_return_value
    # Useful for hosts wanting Rails.error.report's standard return
    # (the error itself). Verifies the call shape doesn't transform it.
    sentinel = Object.new
    Opencode::ErrorReporter.adapter = ->(_error, **_opts) { sentinel }

    result = Opencode::ErrorReporter.report(StandardError.new("x"))
    assert_same sentinel, result
  end
end
