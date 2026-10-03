require "json"
require "./reasoning"

module Liaison
  # A tool the model may call: a name, an optional description, and its
  # parameters as a JSON Schema in **text**. Text because schemas usually
  # arrive as JSON (MCP servers, configuration files), and so this shard takes
  # no schema-generator dependency. A caller with a Crystal type can generate
  # one, for example with `spider-gazelle/json-schema`:
  #
  # ```
  # Tool.new("get_weather", "Look up the weather",
  #   GetWeatherParams.json_schema.to_json)
  # ```
  #
  # Raises `ArgumentError` for an empty name.
  #
  # Tools are what the caller offers on one call, not session history, so they
  # live in `Options` rather than `Session`.
  struct Tool
    getter name : String
    getter description : String?
    getter parameters : String

    EMPTY_SCHEMA = %({"type":"object","properties":{}})

    def initialize(@name : String, @description : String? = nil,
                   @parameters : String = EMPTY_SCHEMA)
      raise ArgumentError.new("tool name cannot be empty") if @name.empty?
    end
  end

  # How the model may use the tools it was offered. Every protocol spells both
  # values and means the same by them, so every mapping is `Exact`.
  #
  # `Required` (call something) and naming a specific tool are not offered. A
  # `case` over this enum is exhaustive today; more values may be added.
  enum ToolChoice
    # The model decides. This is every protocol's own default, so asking for
    # it explicitly matters only when overriding an earlier choice.
    Auto

    # The model may not call a tool on this turn: what a tool loop ends with.
    # Preferred over sending no tools, which also prevents a call but changes
    # the definitions that render ahead of everything else, losing the prefix
    # cache.
    #
    # Gemini disregards this once the conversation holds a tool call, so a
    # caller ending a loop there must check the reply for calls. A completed
    # turn with unanswered calls fails `MPSH::Repair.sendable?`, and `Repair`
    # does not mend it, since it only repairs cut turns.
    None

    # The spelling shared by both OpenAI protocols and Anthropic. Gemini's
    # uppercase modes are in `Protocol::Gemini::TOOL_MODES`.
    def wire_name : String
      case self
      in ToolChoice::Auto then "auto"
      in ToolChoice::None then "none"
      end
    end
  end

  # What the caller wants of this request, as opposed to what the session
  # holds. Separate from `Client`'s `policy` and `retention`, which govern what
  # may be lost translating history; these govern what the model is asked to
  # do next.
  struct Options
    # Tools offered on this call. Empty means no `tools` key is sent.
    getter tools : Array(Tool)

    # The output cap, which every protocol can express. `nil` leaves the
    # provider's default, which on a local endpoint may be unbounded.
    getter max_output_tokens : Int32?

    # How hard to think, as a named rung or a token budget. Both OpenAI
    # protocols take a rung; Anthropic and Gemini take either, depending on the
    # model, and reject being given both.
    #
    # `nil` emits nothing on any protocol, leaving the provider's default.
    # Keep it that way: emitting a default would change every request body
    # that does not ask for reasoning, and invalidate their transcripts.
    getter reasoning : Reasoning::Request?

    # How the offered tools may be used; the tools are still declared. `nil`
    # emits nothing, for the same reason as `reasoning`.
    getter tool_choice : ToolChoice?

    # Raises `ArgumentError` if `tool_choice` is set with no tools, which the
    # OpenAI protocols reject.
    def initialize(@tools : Array(Tool) = [] of Tool,
                   @max_output_tokens : Int32? = nil,
                   @reasoning : Reasoning::Request? = nil,
                   @tool_choice : ToolChoice? = nil)
      if @tool_choice && @tools.empty?
        raise ArgumentError.new("tool_choice needs tools to choose from")
      end
    end

    def tools? : Bool
      !@tools.empty?
    end
  end
end
