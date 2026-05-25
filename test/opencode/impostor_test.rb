# frozen_string_literal: true

require "test_helper"

# Contract smoke for Opencode::Impostor. Wraps an ActiveStorage
# attachment that's been replaced by a Transform-rendered artifact.
# Behavioral tests against real ActiveStorage::Attachment live in
# the host application.
class Opencode::ImpostorTest < Minitest::Test
  def test_initialize_takes_attachment_keyword
    params = Opencode::Impostor.instance_method(:initialize).parameters
    assert_includes params, [ :keyreq, :attachment ],
      "Impostor must require an attachment: keyword (ActiveStorage::Attachment-like)"
  end

  def test_public_api
    assert_equal %i[filename purge!].sort,
      Opencode::Impostor.instance_methods(false).sort
  end

  def test_filename_delegates_to_attachment
    attachment_double = Struct.new(:filename).new("legacy.html")
    impostor = Opencode::Impostor.new(attachment: attachment_double)
    assert_equal "legacy.html", impostor.filename
  end
end
