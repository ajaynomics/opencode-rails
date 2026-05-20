# frozen_string_literal: true

module Opencode
  # A value object that wraps an OpenCode tool part (the shape produced by
  # Opencode::Reply from `message.part.updated` events) and exposes the
  # information a renderer needs — canonical tool name, human labels,
  # target (filepath / pattern / url / command), semantic accessors for
  # rich content (unified diffs, todo lists, bash output, etc.), and an
  # icon identifier.
  #
  # Pure Ruby over ActiveSupport. Lives in the shared Opencode namespace
  # so Blackline views, AIGL views, and any future OpenCode-backed
  # feature can render tool calls consistently.
  #
  # ## Data shape (Opencode::Reply writes this into `parts_json`)
  #
  #   {
  #     "type"     => "tool",
  #     "tool"     => "read" | "edit" | "exa_web_search_exa" | ...,
  #     "status"   => "pending" | "running" | "completed" | "error",
  #     "input"    => { "filePath" => ..., "content" => ..., ... },
  #     "title"    => "..."               (optional, from tool-result)
  #     "error"    => "..."               (only when status == "error")
  #     "metadata" => {                   (optional, from tool-result)
  #       "diff"        => "...unified diff text...",
  #       "diagnostics" => { filePath => [LSP diagnostics] },
  #       "preview"     => "...file preview...",
  #       "matches"     => Integer,
  #       "count"       => Integer,
  #       "output"      => "...bash stdout...",
  #       "stdout"      => "...bash stdout (legacy key)...",
  #       "description" => "...bash description...",
  #       "error"       => truthy when the tool ran but returned an error,
  #     },
  #     "output"   => "...raw tool output string..."
  #   }
  #
  # ## MCP prefix handling
  #
  # OpenCode's MCP adapter prefixes tools with the server name: Exa's
  # `web_search_exa` becomes `exa_web_search_exa` on the wire (double
  # suffix because Exa also names the tool with an `_exa` suffix).
  # `#canonical_tool` strips known MCP prefixes so switching logic can
  # treat `exa_web_search_exa` and `web_search_exa` as the same tool.
  #
  # ## Adding a new tool
  #
  # Add one row to the `TOOLS` table below — every derived concern (kind,
  # gerund, icon, past-tense verb, KNOWN membership) is computed from it.
  #
  # ## Example
  #
  #   display = Opencode::ToolDisplay.new(part)
  #   display.canonical_tool  # => "edit"
  #   display.kind            # => "Edit"
  #   display.gerund          # => "Editing"
  #   display.target          # => "app/models/user.rb"
  #   display.diff            # => "@@ -1,3 +1,4 @@\n..."
  #   display.icon            # => :pencil_square
  #
  class ToolDisplay
    # The single source of truth for every tool we render with dedicated
    # affordances. One row per tool, five columns:
    #
    #   :kind   — noun label  ("Read", "Web search")
    #   :gerund — present-progressive phrase ("Reading", "Searching the web")
    #   :icon   — abstract icon name the view layer maps to an SVG
    #   :past   — past-tense verb ("Read", "Searched", "Wrote")
    #
    # Anything not in this table falls back to generic rendering (humanize
    # the canonical name + OpenCode's title).
    TOOLS = {
      "read"                 => { kind: "Read",             gerund: "Reading",             icon: :document,                  past: "Read" },
      "write"                => { kind: "Write",            gerund: "Writing",             icon: :document_plus,             past: "Wrote" },
      "edit"                 => { kind: "Edit",             gerund: "Editing",             icon: :pencil_square,             past: "Edited" },
      "multiedit"            => { kind: "Edit",             gerund: "Editing",             icon: :pencil_square,             past: "Edited" },
      "apply_patch"          => { kind: "Patch",            gerund: "Applying changes",    icon: :pencil_square,             past: "Applied changes to" },
      "bash"                 => { kind: "Bash",             gerund: "Running command",     icon: :command_line,              past: "Ran" },
      "grep"                 => { kind: "Grep",             gerund: "Searching files",     icon: :document_magnifying_glass, past: "Searched for" },
      "glob"                 => { kind: "Glob",             gerund: "Searching files",     icon: :magnifying_glass,          past: "Searched for" },
      "list"                 => { kind: "LS",               gerund: "Listing files",       icon: :rectangle_stack,           past: "Listed" },
      "ls"                   => { kind: "LS",               gerund: "Listing files",       icon: :rectangle_stack,           past: "Listed" },
      "webfetch"             => { kind: "Fetch",            gerund: "Reading web page",    icon: :globe,                     past: "Fetched" },
      "websearch"            => { kind: "Web search",       gerund: "Searching the web",   icon: :globe,                     past: "Searched" },
      "codesearch"           => { kind: "Code search",      gerund: "Searching code",      icon: :magnifying_glass,          past: "Searched code for" },
      "web_search_exa"       => { kind: "Web search",       gerund: "Searching the web",   icon: :globe,                     past: "Searched" },
      # @zhafron/mcp-web-search exposes two tools: search_web (SearXNG meta-
      # search) and fetch_url (Mozilla Readability page fetch). OpenCode
      # prefixes them with the MCP server name from config.json
      # (`local-web-search_`), which `canonical_tool` strips before lookup.
      "search_web"           => { kind: "Web search",       gerund: "Searching the web",   icon: :globe,                     past: "Searched" },
      "fetch_url"            => { kind: "Fetch",            gerund: "Reading web page",    icon: :globe,                     past: "Fetched" },
      "get_code_context_exa" => { kind: "Code lookup",      gerund: "Looking up code",     icon: :document_magnifying_glass, past: "Looked up" },
      "company_research_exa" => { kind: "Company research", gerund: "Researching company", icon: :globe,                     past: "Researched" },
      "todowrite"            => { kind: "Plan",             gerund: "Planning",            icon: :queue_list,                past: "Updated plan" },
      "todoread"             => { kind: "Plan",             gerund: "Reading plan",        icon: :queue_list,                past: "Read plan" },
      "task"                 => { kind: "Task",             gerund: "Researching",         icon: :robot,                     past: "Ran subtask" },
      "skill"                => { kind: "Skill",            gerund: "Loading skill",       icon: :sparkles,                  past: "Loaded skill" }
    }.freeze

    KNOWN = TOOLS.keys.freeze
    DEFAULT_ICON = :sparkles

    # MCP server prefixes to strip, paired with the tools they canonicalize
    # to (for `#provider` classification). Prefixes sorted by length
    # descending in case future additions overlap.
    PROVIDERS = {
      "exa"              => { prefix: "exa_",              canonical: %w[web_search_exa get_code_context_exa company_research_exa].freeze },
      "brave"            => { prefix: "brave_",            canonical: [].freeze },
      "serper"           => { prefix: "serper_",           canonical: [].freeze },
      "tavily"           => { prefix: "tavily_",           canonical: [].freeze },
      # The local-web-search MCP server registered in
      # config/opencode/<product>/config.json. Hyphenated server name plus
      # underscore separator; canonical tools are search_web and fetch_url.
      "local-web-search" => { prefix: "local-web-search_", canonical: %w[search_web fetch_url].freeze }
    }.freeze

    MCP_PREFIXES = PROVIDERS.values.map { |p| p[:prefix] }.freeze

    attr_reader :part

    def initialize(part)
      @part = part || {}
    end

    # Convenience constructor for raw OpenCode API parts (symbol keys,
    # nested under `state`). Flattens into the canonical `parts_json`
    # shape Reply persists.
    #
    #   raw = { type: "tool", tool: "bash", callID: ...,
    #           state: { status: "running", input: {...}, title: "..." } }
    #   Opencode::ToolDisplay.from_raw(raw)
    def self.from_raw(raw)
      raw = (raw || {}).deep_stringify_keys
      state = raw["state"] || {}
      new(
        "type"     => "tool",
        "tool"     => raw["tool"],
        "status"   => state["status"],
        "input"    => state["input"] || {},
        "output"   => state["output"],
        "title"    => state["title"],
        "error"    => state["error"],
        "metadata" => state["metadata"] || {}
      )
    end

    # ----- Identity -----------------------------------------------------

    def tool_name
      @part["tool"].to_s
    end

    # Strips MCP prefixes — and, when present, the matching MCP suffix —
    # so tools render cleanly regardless of how the server namespaces them.
    #
    # Examples:
    #   exa_web_search_exa → web_search_exa (KNOWN tool, preserved)
    #   exa_web_fetch_exa  → web_fetch      (not KNOWN; cleaned for display)
    #   exa_nonexistent    → nonexistent    (prefix-stripped fallback)
    #   brave_read         → read           (KNOWN after prefix strip)
    #
    # The double-strip handles Exa's naming convention: the MCP server
    # exports tools like `web_fetch_exa`, and OpenCode prepends `exa_`,
    # producing `exa_web_fetch_exa`. Stripping both yields a readable
    # `web_fetch`.
    def canonical_tool
      name = tool_name
      return name if name.empty? || KNOWN.include?(name)

      MCP_PREFIXES.each do |prefix|
        stripped = strip_mcp_decoration(name, prefix)
        return stripped if stripped
      end
      name
    end

    def known?
      KNOWN.include?(canonical_tool)
    end

    def icon
      TOOLS.dig(canonical_tool, :icon) || DEFAULT_ICON
    end

    # "Read", "Edit", "Bash", or a humanized *canonical* name for unknowns.
    # Humanizes `canonical_tool`, not `tool_name` — otherwise an MCP tool
    # like `exa_web_fetch_exa` whose canonical form (`web_fetch`) isn't
    # in TOOLS would fall back to the raw, MCP-prefixed name and display
    # as "Exa web fetch exa". Using the canonical form gives the clean
    # "Web fetch" label.
    def kind
      TOOLS.dig(canonical_tool, :kind) || canonical_tool.humanize
    end

    # "Reading", "Editing", "Running command", falls back to "<kind>...".
    def gerund
      TOOLS.dig(canonical_tool, :gerund) || "#{kind}..."
    end

    # ----- Status -------------------------------------------------------

    def status
      @part["status"].to_s
    end

    def pending?    = status == "pending"
    def running?    = status == "running"
    def completed?  = status == "completed"
    def errored?    = status == "error"
    def terminal?   = completed? || errored?
    def in_flight?  = pending? || running?

    # ----- Raw payloads -------------------------------------------------

    def input
      @part["input"].is_a?(Hash) ? @part["input"] : {}
    end

    def metadata
      @part["metadata"].is_a?(Hash) ? @part["metadata"] : {}
    end

    def output
      @part["output"].to_s
    end

    def error_text
      @part["error"].to_s
    end

    # OpenCode-supplied title (from tool-result). Used as a fallback for
    # unknown MCP tools that don't match KNOWN.
    def opencode_title
      @part["title"].to_s
    end

    # ----- Target (what the tool is operating on) ----------------------

    # Returns a single-string representation of the tool's primary target,
    # or nil when the tool has no meaningful single target. Callers can
    # substitute display-friendly names (e.g., sandbox filenames).
    def target
      raw = case canonical_tool
      when "read", "write", "edit", "multiedit", "apply_patch"
              input["filePath"] || input["path"]
      when "bash"
              input["command"]
      when "grep", "glob"
              input["pattern"]
      when "list", "ls"
              input["path"]
      when "webfetch", "fetch_url"
              input["url"]
      when "websearch", "codesearch",
                 "web_search_exa", "get_code_context_exa", "company_research_exa"
              input["query"]
      when "search_web"
              # @zhafron/mcp-web-search names the argument `q`, not `query`.
              input["q"]
      when "task"
              input["description"]
      when "skill"
              input["skill_name"] || input["name"]
      end
      raw.to_s.presence
    end

    # A short label combining kind + target, suitable for a one-line
    # summary. Falls back to the OpenCode-supplied title for unknown MCP
    # tools, then to just kind.
    def title
      if known?
        target.present? ? "#{kind}: #{target}" : kind
      else
        opencode_title.presence || kind
      end
    end

    # Past-tense "done" variant: "Read foo.rb", "Wrote contract.pdf",
    # "Edited user.rb", "Ran `ls -la`". Used after completion.
    def past_tense_title
      if known?
        verb = TOOLS.dig(canonical_tool, :past)
        return kind unless verb
        target.present? ? "#{verb} #{target}" : verb
      else
        opencode_title.presence || kind
      end
    end

    # ----- Semantic accessors (rich content) ---------------------------

    # Unified-diff text produced by the edit tool (OpenCode attaches this
    # under metadata.diff). Present only after completion.
    def diff
      metadata["diff"].presence
    end

    # Sorted list of todo hashes { "content", "status", "priority", "id" }.
    # Available during running (input is populated) and completed states.
    # Order: in_progress first, pending next, completed last.
    # Canonicalization (string keys + status hyphen→underscore) is
    # delegated to Opencode::Todo so Reply and ToolDisplay can't drift.
    def todos
      return [] unless %w[todowrite todoread].include?(canonical_tool)
      items = input["todos"]
      return [] unless items.is_a?(Array)
      order = { "in_progress" => 0, "pending" => 1, "completed" => 2 }
      items
        .select { |t| t.is_a?(Hash) }
        .map    { |todo| Opencode::Todo.canonicalize(todo) }
        .sort_by { |todo| order[todo["status"]] || 99 }
    end

    # File content that the write tool is creating (lives in input.content).
    def file_content
      return nil unless canonical_tool == "write"
      input["content"].presence
    end

    # Syntax-highlighting language hint based on the target filename.
    # Falls back to the raw extension so unknown file types still get a
    # hint their syntax-highlighter may recognize heuristically.
    def file_lang
      name = File.basename(target.to_s)
      return nil if name.empty?
      ext = File.extname(name).delete_prefix(".").downcase
      LANG_BY_EXT[ext] || ext.presence
    end

    LANG_BY_EXT = {
      "md"   => "markdown", "markdown" => "markdown",
      "rb"   => "ruby",     "rake"     => "ruby",
      "py"   => "python",
      "js"   => "javascript", "mjs"    => "javascript",
      "ts"   => "typescript", "tsx"    => "typescript",
      "jsx"  => "jsx",
      "json" => "json",     "yml"      => "yaml",     "yaml"  => "yaml",
      "html" => "html",     "erb"      => "erb",
      "css"  => "css",      "scss"     => "scss",
      "sh"   => "shell",    "bash"     => "shell",    "zsh"   => "shell",
      "sql"  => "sql",
      "go"   => "go",       "rs"       => "rust",
      "c"    => "c",        "h"        => "c",
      "cpp"  => "cpp",      "hpp"      => "cpp",
      "java" => "java",     "kt"       => "kotlin",
      "swift" => "swift",   "php"      => "php",
      "lua"  => "lua",      "toml"     => "toml",
      "xml"  => "xml",      "conf"     => "shell"
    }.freeze

    # Bash-specific accessors.
    def bash_command
      return nil unless canonical_tool == "bash"
      input["command"].presence
    end

    def bash_output
      return nil unless canonical_tool == "bash"
      (metadata["output"] || metadata["stdout"] || output).to_s.presence
    end

    def bash_description
      return nil unless canonical_tool == "bash"
      metadata["description"].presence
    end

    # Read preview (OpenCode populates metadata.preview after the read).
    def read_preview
      return nil unless canonical_tool == "read"
      metadata["preview"].presence
    end

    # Grep/Glob match counts.
    def match_count
      case canonical_tool
      when "grep" then metadata["matches"].to_i
      when "glob" then metadata["count"].to_i
      end
    end

    # ----- Provider identification for log tagging ---------------------

    # Groups tools by which MCP server / built-in provides them, for
    # operational logs and metrics. Adding a new provider = one row in
    # PROVIDERS.
    def provider
      name = tool_name
      canonical = canonical_tool
      PROVIDERS.each do |provider_name, config|
        return provider_name if name.start_with?(config[:prefix])
        return provider_name if config[:canonical].include?(canonical)
      end
      KNOWN.include?(canonical) ? "opencode-builtin" : "unknown"
    end

    private

    # Returns `name` with `prefix` (and the matching MCP suffix, where
    # Exa double-encodes) removed, or nil when `name` doesn't carry that
    # prefix. Precedence:
    #
    #   1. Prefer the single-stripped form when it's KNOWN
    #      (exa_web_search_exa → web_search_exa, which IS a TOOLS key).
    #   2. Otherwise prefer the clean double-stripped form when both
    #      prefix and suffix are present
    #      (exa_web_fetch_exa → web_fetch, for humanization).
    #   3. Fall back to single-stripped when double-stripped is empty.
    def strip_mcp_decoration(name, prefix)
      return nil unless name.start_with?(prefix)

      stripped = name.delete_prefix(prefix)
      return stripped if KNOWN.include?(stripped)

      suffix = "_#{prefix.chomp('_')}"
      return stripped unless stripped.end_with?(suffix)

      double = stripped.delete_suffix(suffix)
      double.empty? ? stripped : double
    end
  end
end
