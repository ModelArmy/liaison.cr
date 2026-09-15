require "json"
require "./reasoning"

module Liaison
  # A tool the model may call.
  #
  # `parameters` is a JSON Schema as **text**, not a parsed structure. That is
  # deliberate: a schema's natural interchange form is JSON, it arrives that
  # way from MCP servers and configuration files, and a caller who generates
  # one from a Crystal type can hand over the result without this shard needing
  # to know how it was produced.
  #
  # Callers wanting compile-time schemas can pair this with a generator — for
  # example `spider-gazelle/json-schema`:
  #
  # ```
  # Tool.new("get_weather", "Look up the weather",
  #   GetWeatherParams.json_schema.to_json)
  # ```
  #
  # That shard stays *their* dependency, not ours. Taking it here would make
  # every consumer carry it, and would force a Crystal type on callers whose
  # schema arrives as text — the common case.
  #
  # Note that tools are not session history. They are what the caller offers on
  # *this* call, which is why they live in `Options` and not in `Session`: a
  # stored conversation that carried its own tool list would have acquired a
  # home, and portability is exactly the thing this shard refuses to give up.
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

  # How the model may use the tools it was offered.
  #
  # Two values, because two is what every protocol here agrees about. `Auto`
  # and `None` mean the same thing on all four and are accepted by all four,
  # so nothing in `Capability` mediates this: unlike `reasoning`, there is no
  # disagreement to reconcile and every mapping is `Exact`.
  #
  # **Accepted is not honoured.** Gemini disregards `None` once the
  # conversation contains a tool call — proven across two model generations,
  # with this shard's mapping ruled out as the cause; see
  # `docs/protocols/GEMINI.md`. The other three enforce it. A caller ending a
  # tool loop on Gemini must therefore check the reply rather than trust the
  # request, because a completed turn holding unasked-for calls is the one
  # shape `MPSH::Repair.sendable?` forbids and `Repair` will not mend.
  #
  # The missing third value is `Required` — "call something" — and it is
  # missing deliberately rather than by oversight. It is model-gated on at
  # least one protocol and conflicts with `reasoning` on the same one, so it
  # needs a `Capability::Catalog` axis and a cross-option rule that neither
  # value here does. `SCOPE.md` carries both traps. The fourth form, naming a
  # specific tool, would carry an argument and turn this into a union.
  #
  # Expect the vocabulary to grow. A `case` over it is exhaustive today, not
  # closed forever.
  enum ToolChoice
    # The model decides. This is every protocol's own default, so asking for
    # it explicitly matters only when overriding an earlier choice.
    Auto

    # The model may not call a tool on this turn.
    #
    # What a tool loop ends with. The alternative available before this
    # existed — sending the final request with no tools — is a 400 on
    # Anthropic for any session whose history holds tool blocks, and a lost
    # prefix cache on the rest.
    None

    def wire_name : String
      case self
      in ToolChoice::Auto then "auto"
      in ToolChoice::None then "none"
      end
    end

    # Gemini shouts its modes, as it does its reasoning levels.
    def gemini_mode : String
      wire_name.upcase
    end
  end

  # What the caller wants of *this* request, as opposed to what the session
  # remembers.
  #
  # Kept apart from `policy` and `retention`, which are fidelity controls —
  # they govern what may be lost in translating history. These govern what the
  # model is asked to do next. Two different questions that happen to travel on
  # the same call.
  #
  struct Options
    getter tools : Array(Tool)

    # The one generation parameter every protocol can express, in four
    # spellings. Absent means "whatever the provider defaults to", which on a
    # local endpoint can mean a model reasoning until something gives — a
    # failure this suite has already met.
    getter max_output_tokens : Int32?

    # How hard to think, in whichever of two units the caller prefers. Unlike
    # the output cap, this is the one request option no two protocols agree
    # about: three take a named rung, two take a token budget, and the ones
    # that take both reject being given both.
    #
    # **Absent means absent.** Nothing is emitted on any protocol, and the
    # provider's own default stands. That is load-bearing rather than tidy: it
    # keeps every request body that does not ask for reasoning byte-identical
    # to what it was before this option existed, so no recorded transcript is
    # re-cut by adding it.
    getter reasoning : Reasoning::Request?

    # How the offered tools may be used. The tools are still declared and
    # still emitted; this only constrains what the model may do with them.
    #
    # **Absent means absent**, on `reasoning`'s terms and for the same reason:
    # nothing is emitted on any protocol, the provider's own default stands,
    # and a request that does not ask for a choice is byte-identical to one
    # built before this option existed.
    getter tool_choice : ToolChoice?

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
