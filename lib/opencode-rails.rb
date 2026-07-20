# frozen_string_literal: true

# opencode-rails — Production Rails integration for OpenCode.
#
# Loads the wire-level primitives from opencode-ruby, then layers on the
# AR-coupled session/turn/artifact stack. Caller-facing namespace stays
# flat at `Opencode::*` (no `Opencode::Rails::Session` etc.) so this gem
# can drop into any app that already uses opencode-ruby with zero
# rename work.

require "opencode-ruby"
require "fileutils"
require "marcel"
require "pathname"
require "set"
require "stringio"
require "tempfile"

require "active_support/core_ext/object/blank"      # blank?, present?, presence
require "active_support/core_ext/object/try"
require "active_support/core_ext/hash/keys"          # deep_stringify_keys, deep_symbolize_keys
require "active_support/core_ext/string/inflections" # demodulize, underscore, camelize
require "active_support/core_ext/string/filters"     # squish, truncate
require "active_support/core_ext/numeric/time"       # 2.seconds, 5.minutes, etc.

require_relative "opencode/rails_version"
require_relative "opencode/error_reporter"

# Tier 4 leaves (no deps on other rails-gem files)
require_relative "opencode/sandbox_file"
require_relative "opencode/sandbox"
require_relative "opencode/transform"
require_relative "opencode/impostor"
require_relative "opencode/artifact"
require_relative "opencode/message_artifacts"
require_relative "opencode/uploaded_files_prompt"
require_relative "opencode/tool_display"
require_relative "opencode/exchange"

# Tier 3 (depend on the leaves above)
require_relative "opencode/session"
require_relative "opencode/turn"

module Opencode
end
