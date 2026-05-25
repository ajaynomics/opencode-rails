# frozen_string_literal: true

require "test_helper"

# Smoke tests for Opencode::ToolDisplay — the view-model that converts
# raw tool-part hashes into Turbo-Stream-friendly props. We exercise
# the predicate surface for the canonical 'read' tool plus the
# unknown-tool fallback. Exhaustive per-tool render tests live in the
# host where the renderer templates are exercised.
class Opencode::ToolDisplayTest < Minitest::Test
  def test_known_read_tool_canonicalization
    display = Opencode::ToolDisplay.new(
      "type" => "tool", "tool" => "read", "status" => "completed",
      "input" => { "filePath" => "/sandbox/notes.md" }
    )

    assert_equal "read", display.canonical_tool
    assert display.known?
    assert display.completed?
    assert display.terminal?
    refute display.errored?
    refute display.in_flight?
  end

  def test_running_status
    display = Opencode::ToolDisplay.new("type" => "tool", "tool" => "read", "status" => "running")
    assert display.in_flight?
    refute display.terminal?
    refute display.completed?
  end

  def test_errored_status
    display = Opencode::ToolDisplay.new(
      "type" => "tool", "tool" => "edit", "status" => "error", "error" => "permission denied"
    )
    assert display.errored?
    assert display.terminal?
    refute display.completed?
  end

  def test_unknown_tool_falls_back_gracefully
    display = Opencode::ToolDisplay.new("type" => "tool", "tool" => "wat", "status" => "completed")
    refute display.known?,
      "Unknown tools must not claim to be known — host renderer dispatches a fallback view"
    refute_nil display.canonical_tool,
      "Unknown tools still need a canonical_tool so DOM ids stay stable"
  end

  def test_nil_part_initializes_safely
    # ToolDisplay tolerates a nil part because callers sometimes pass
    # message.parts_json entries that aren't tool parts.
    display = Opencode::ToolDisplay.new(nil)
    refute display.known?
  end
end
