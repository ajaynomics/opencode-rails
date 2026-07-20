# frozen_string_literal: true

# NOTE: we deliberately do NOT define `Opencode::Rails` as a module —
# host applications often have files inside the `Opencode::` namespace
# that reference top-level `::Rails.something`. Defining
# `Opencode::Rails` would shadow `::Rails` under Ruby's constant
# lookup rules (`Rails.root` would resolve to `Opencode::Rails.root`
# and raise NoMethodError).
#
# The opencode-ruby gem uses `Opencode::VERSION` for its own version.
# We can't reuse the same constant from a second gem, so we use a
# distinct, non-namespaced constant.
module Opencode
  RAILS_VERSION = "0.0.1.alpha8"
end
