# frozen_string_literal: true

require "test_helper"

# Smoke test for Opencode::Artifact — verifies the value-object surface
# (filename/content/content_type readers). Behavioral tests around how
# the host's ActiveStorage-backed AIGL::Trip/etc. records build artifact
# collections live in the host's test suite.
class Opencode::ArtifactTest < Minitest::Test
  def test_value_object_readers
    artifact = Opencode::Artifact.new(
      filename: "notes.md",
      content: "# Notes",
      content_type: "text/markdown"
    )

    assert_equal "notes.md", artifact.filename
    assert_equal "# Notes", artifact.content
    assert_equal "text/markdown", artifact.content_type
  end

  def test_metadata_defaults_to_empty_hash
    artifact = Opencode::Artifact.new(filename: "x.txt", content: "hi", content_type: "text/plain")
    assert_equal({}, artifact.metadata)
  end

  def test_metadata_accepts_trust_hash
    artifact = Opencode::Artifact.new(
      filename: "x.html",
      content: "<p>",
      content_type: "text/html",
      metadata: { trust: "host_rendered" }
    )
    assert_equal "host_rendered", artifact.metadata[:trust]
  end
end
