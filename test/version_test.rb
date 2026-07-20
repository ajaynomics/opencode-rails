# frozen_string_literal: true

require "test_helper"

class Opencode::VersionTest < Minitest::Test
  GEMSPEC_PATH = File.expand_path("../opencode-rails.gemspec", __dir__)

  def test_alpha_versions_and_runtime_dependency_stay_in_lockstep
    specification = Gem::Specification.load(GEMSPEC_PATH)
    dependency = specification.runtime_dependencies.find { |item| item.name == "opencode-ruby" }

    refute_nil dependency
    assert_equal Opencode::RAILS_VERSION, Opencode::VERSION
    assert_equal "= #{Opencode::RAILS_VERSION}", dependency.requirement.to_s
  end
end
