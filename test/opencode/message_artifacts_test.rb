# frozen_string_literal: true

require "test_helper"

# Contract smoke for Opencode::MessageArtifacts (the idempotent
# ActiveStorage-backed artifact attachment pipeline). Behavioral
# coverage — including ActiveStorage attachment, Transform application,
# error reporting via Opencode::ErrorReporter — lives in the host app.
class Opencode::MessageArtifactsTest < Minitest::Test
  Message = Struct.new(:id, keyword_init: true)
  Sandbox = Struct.new(:entries, keyword_init: true) do
    def exists? = true
    def files(after: nil) = entries
  end
  SandboxEntry = Struct.new(:basename, :attached, keyword_init: true) do
    def as_artifact
      self.attached = true
      raise "destination must not use the identity attachment path"
    end
  end

  class Transform < Opencode::Transform
    def source_filename = "source.json"
    def destination_filename = "rendered.html"
  end

  def test_initialize_takes_message_feature_and_optional_transforms
    params = Opencode::MessageArtifacts.instance_method(:initialize).parameters
    by_kind = params.group_by(&:first).transform_values { |list| list.map(&:last) }

    assert_includes by_kind[:keyreq], :message,
      "MessageArtifacts must require a message: keyword"
    assert_includes by_kind[:keyreq], :feature,
      "MessageArtifacts must require a feature: keyword (used in error reports)"
    assert_includes by_kind[:key] || [], :transforms,
      "MessageArtifacts must accept an optional transforms: keyword"
  end

  def test_public_api_is_attach_from
    assert_equal [ :attach_from ], Opencode::MessageArtifacts.instance_methods(false),
      "MessageArtifacts's only public verb is #attach_from"
  end

  def test_agent_authored_transform_destination_never_uses_default_attachment
    entry = SandboxEntry.new(basename: "rendered.html", attached: false)
    artifacts = Opencode::MessageArtifacts.new(
      message: Message.new(id: 1),
      feature: "test",
      transforms: [ Transform.new ]
    )

    artifacts.attach_from(sandbox: Sandbox.new(entries: [ entry ]))

    refute entry.attached
  end
end
