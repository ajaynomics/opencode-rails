# frozen_string_literal: true

require "test_helper"

# Smoke test for Opencode::Transform — the base class for
# content-rewriting transforms. It is intentionally abstract:
# #source_filename, #destination_filename, and #render all raise
# NotImplementedError. Subclasses (host-side) provide the meat.
# These tests document the abstract contract.
class Opencode::TransformTest < Minitest::Test
  def test_source_filename_is_abstract
    err = assert_raises(NotImplementedError) { Opencode::Transform.new.source_filename }
    assert_match(/must implement #source_filename/, err.message)
  end

  def test_destination_filename_is_abstract
    err = assert_raises(NotImplementedError) { Opencode::Transform.new.destination_filename }
    assert_match(/must implement #destination_filename/, err.message)
  end

  def test_render_is_abstract
    err = assert_raises(NotImplementedError) { Opencode::Transform.new.render(Object.new) }
    assert_match(/must implement #render/, err.message)
  end

  def test_purge_impostors_defaults_to_false
    refute Opencode::Transform.new.purge_impostors?,
      "Default #purge_impostors? must be false — conservative opt-in by subclasses"
  end

  # A trivial concrete subclass exercises the defaults that DO exist
  # (#applies_to? and #owned_filenames delegate to the
  # two abstract filename methods).
  class FakeTransform < Opencode::Transform
    def source_filename = "agent-output.json"
    def destination_filename = "rendered.html"
  end

  Attachment = Struct.new(:filename, keyword_init: true)
  Basenamed = Struct.new(:basename, keyword_init: true)

  def test_applies_to_matches_source_filename_by_default
    transform = FakeTransform.new
    matching = Basenamed.new(basename: "agent-output.json")
    other    = Basenamed.new(basename: "something-else.json")

    assert transform.applies_to?(matching)
    refute transform.applies_to?(other)
  end

  def test_trusted_fails_closed_by_default
    transform = FakeTransform.new
    destination = Attachment.new(filename: "rendered.html")

    refute transform.trusted?(destination)
  end

  def test_owned_filenames_is_source_and_destination
    assert_equal %w[agent-output.json rendered.html],
      FakeTransform.new.owned_filenames
  end

  def test_error_is_a_subclass_of_standarderror
    assert_operator Opencode::Transform::Error, :<, StandardError,
      "Transform::Error must be rescuable by `rescue StandardError`"
  end
end
