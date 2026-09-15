require "../spec_helper"

# Live specs against the real Anthropic Messages API — the first paid
# endpoint, and the first that can *validate* rather than merely accept. Every
# claim recorded here is one Ollama's Anthropic-compatible port could not
# settle: it ignores thinking signatures and rung/budget spellings alike, so a
# green run there proves acceptance and nothing about correctness. See
# `docs/servers/OLLAMA.md`.
#
# **Recording.** Needs `ANTHROPIC_API_KEY` in the environment and `RECORD=1`
# to cut a transcript. Once committed it replays offline like every other live
# spec — nobody after the first recording needs a key. See *Live specs* in
# `DEVELOPMENT.md` for the two-step recording procedure; the run after the
# recording is the one that proves anything.
#
# **Model.** Pinned to a Haiku throughout. This suite is about protocol
# fidelity, not model capability, so the cheapest current model that exercises
# the path in question is the right one. Flagged per-example if a path turns
# out to need a different model.
private MODEL = "claude-haiku-4-5"

private def anthropic : Liaison::Server
  Liaison::Server.new("anthropic", "https://api.anthropic.com", ENV["ANTHROPIC_API_KEY"]?)
end

private def client(policy : Liaison::Capability::Policy = Liaison::Capability::Policy::Compensating) : Liaison::Client
  Liaison::Client.new(Liaison::Provider.for(anthropic, Liaison::ProtocolKind::Anthropic), policy)
end

private def weather_tool : Liaison::Tool
  Liaison::Tool.new("get_weather", "Look up the current weather in a city",
    %({"type":"object","properties":{"city":{"type":"string","description":"City name"}},"required":["city"]}))
end

# What used to live here — a signature-less `thinking` block sent to this
# endpoint and expected to 400 — moved to `spec/conformance/anthropic_spec.cr`
# ("declared divergences") once the fix landed. `Policy::Compensating` now
# refuses that shape before a request is ever built, so there is nothing left
# for a network call to prove about the behaviour.
#
# The recording itself was lost, and is `SCOPE.md`'s only MUST FIX. It was
# never committed, and because the fix meant nothing replayed it, no test
# noticed. Its home is here when it comes back: a replay asserts Anthropic's
# schema rather than anything this shard does, so it can never go red for a
# change here — which is what `spec/live/` is for, and is also exactly why it
# needs a consumer rather than merely a file.
#
# Recording A is next: a real signed `thinking` block, requested with
# `Reasoning::Effort` against a budget-only model, replayed on the next turn.
# It confirms the own-vendor Exact path actually works and the
# `REASONING_BUDGETS` clamp is shaped right — both still genuinely need a
# paid call, and neither changed when the fix above landed.
describe "Anthropic" do
  # `claude-haiku-4-5` is in `Catalog::BUDGET_ONLY`, so `Effort::Low` resolves
  # to `thinking.budget_tokens: 1024` — the floor, and the cheapest way to
  # exercise both the clamp and the budget spelling in one call. `cap: 1536`
  # leaves room above the 1024 floor for an actual answer, since thinking and
  # answer tokens share one ceiling (`mapper.cr`'s `clamped_budget`).
  describe "a real signed thinking block" do
    it "is requested, accepted, and replays clean on the next turn" do
      Wiretap.intercept("anthropic_thinking_signature_replay") do
        session = M::Session.new("You are terse.")
        session << M::Message.user("What is the tallest mountain on Earth?")

        first, first_report = client.send(session, MODEL,
          options: Liaison::Options.new(
            reasoning: Liaison::Reasoning::Effort::Low,
            max_output_tokens: 1536))
        session << first

        # Restructured, not Exact — two independent reasons, both by design.
        # `REASONING_BUDGETS` renders a rung as a token count
        # (`reasoning_control.cr`: `Effort → AsBudget` is Restructured even
        # for the vendor's own rung), and separately, `MoveSystemPrompt` is
        # unconditionally Restructured whenever a system prompt exists here —
        # `structural.cr`'s `outcome` does not check whether the destination's
        # own native placement is exactly where it's going. Either alone caps
        # this turn below Exact; nothing here says the budget path failed.
        first_report.worst.should eq M::Outcome::Restructured
        reasoning = first.content.select(M::ReasoningBlock).first?
        reasoning.should_not be_nil
        reasoning.not_nil!.meta?("anthropic", "signature").should_not be_nil

        session << M::Message.user("And the deepest ocean trench?")

        # The point of the second call: not a fresh request, a *replay* of the
        # signature Anthropic itself just issued. Own-vendor, default policy.
        #
        # `report.worst` cannot be the check here — this turn's `system` field
        # alone already caps it at Restructured, same as turn one, and for the
        # same unconditional `MoveSystemPrompt` reason, nothing to do with
        # reasoning. What actually proves the replay: no Degraded or Refused
        # annotation anywhere in this turn. If `replayable?` had rejected the
        # signature, dropping the block would be exactly that.
        second, second_report = client.send(session, MODEL)

        second_report.annotations.map(&.outcome).should_not contain(M::Outcome::Degraded)
        second_report.annotations.map(&.outcome).should_not contain(M::Outcome::Refused)
        second.content.select(M::TextBlock).should_not be_empty
      end
    end
  end

  # Ending a tool loop, on the protocol where nothing else can.
  #
  # These are the examples the option was built for, and the only ones that can
  # falsify anything. Ollama's ports accept the field and prove the shape; they
  # cannot show the model withheld a call it would otherwise have made, because
  # they accept more than they enforce.
  #
  # Note what both requests demonstrate in passing. The tools are still
  # declared, which is not optional here: this endpoint rejects any request
  # whose history holds `tool_use` or `tool_result` blocks and does not define
  # tools, so emptying the array — the only guarantee available before this
  # option existed — is a 400 rather than a fallback. See
  # `docs/protocols/ANTHROPIC.md`.
  describe "a turn that may not call a tool" do
    # The falsifying one, and deliberately the harshest arrangement available:
    # a completed exchange for one city, then a question about a second city
    # with the tool still on the table. Under `Auto` that is a tool call. It
    # is not one here.
    #
    # It also answers a question the shape of the option cannot: **`None`
    # guarantees no call, not an answer.** Asked something it could only have
    # resolved by calling, and forbidden from calling, the model returned an
    # empty turn — `content: []`, `stop_reason: end_turn` — rather than
    # explaining itself. So a caller who ends a loop with a question the
    # history cannot answer gets nothing, and archives an empty assistant
    # message. Survivable: `normalize` drops empty messages on the next
    # request and records `DropEmptyMessage`. Still a loss, and cheaper to
    # avoid than to absorb — see the example below for the shape that does.
    it "withholds the call where a call is the obvious move" do
      Wiretap.intercept("anthropic_tool_choice_none") do
        call = M::ToolCallBlock.new("mc_live_weather", "get_weather",
          M::Object{"city" => "Paris"})
        session = M::Session.new("Use the supplied tools when they apply.")
        session << M::Message.user("What is the weather in Paris?")
        session << M::Message.new(M::Role::Assistant, [call.as(M::Block)])
        session << M::Message.new(M::Role::User,
          [M::ToolResultBlock.new(call.call_id,
            [M::TextBlock.new("18C, light rain").as(M::Block)]).as(M::Block)])
        session << M::Message.user("And in Berlin?")

        reply, report = client.send(session, MODEL,
          options: Liaison::Options.new(tools: [weather_tool],
            max_output_tokens: 512,
            tool_choice: Liaison::ToolChoice::None))

        # The claim, stated directly, and the whole of it.
        reply.content.select(M::ToolCallBlock).should be_empty
        report.annotations.map(&.outcome).should_not contain(M::Outcome::Refused)
      end
    end

    # What a bounded host actually sends: the history ends with a tool result,
    # nothing further is asked, and the turn exists to say what was found.
    # Answerable without calling anything, which is the difference from the
    # example above — and the reason that one returns nothing and this one
    # returns prose.
    it "answers from what the history already holds" do
      Wiretap.intercept("anthropic_tool_choice_none_summary") do
        call = M::ToolCallBlock.new("mc_live_weather", "get_weather",
          M::Object{"city" => "Paris"})
        session = M::Session.new("Use the supplied tools when they apply.")
        session << M::Message.user("What is the weather in Paris?")
        session << M::Message.new(M::Role::Assistant, [call.as(M::Block)])
        session << M::Message.new(M::Role::User,
          [M::ToolResultBlock.new(call.call_id,
            [M::TextBlock.new("18C, light rain").as(M::Block)]).as(M::Block)])

        reply, report = client.send(session, MODEL,
          options: Liaison::Options.new(tools: [weather_tool],
            max_output_tokens: 512,
            tool_choice: Liaison::ToolChoice::None))

        reply.content.select(M::ToolCallBlock).should be_empty
        reply.content.select(M::TextBlock).should_not be_empty
        report.annotations.map(&.outcome).should_not contain(M::Outcome::Refused)
      end
    end
  end
end
