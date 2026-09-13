require "../spec_helper"
require "../support/saved_session"

# A `Toolbox` against a real endpoint, and the archive it leaves behind.
#
# **The gap this closes.** `spec/toolbox_spec.cr` proves every route through
# `#dispatch` produces a sendable session, entirely offline — hand-built replies
# and hand-built calls. Nothing proves a model ever *emits* a call our
# declarations describe, or *accepts* a result our dispatch produced. Those are
# the two ends the offline spec cannot reach, and they are the ends that fail
# when a mapper is wrong.
#
# **What is asserted, and what is not.** Whether a model chooses to call
# `get_weather` is the model's business, and asserting it is how every live
# failure in this repo has started. What is asserted is our translation: that a
# call it did emit round-trips, that the result we paired to it is accepted, and
# that the session holding both survives a file. A recording where the model
# answered from memory instead would fail the first example — and that is a
# recording to redo, not an assertion to soften.
private MODEL = "gemma4:26b-mxfp8"

private TOOL_TURN    = "e2e_tool_turn"
private TOOL_HANDOFF = "e2e_tool_turn_handoff"

private class Weather
  include Liaison::Function

  def name : String
    "get_weather"
  end

  def description : String?
    "Look up the current weather in a city"
  end

  def parameters : String
    %({"type":"object","properties":{"city":{"type":"string","description":"City name"}},"required":["city"]})
  end

  def call(arguments : M::Object) : Array(M::Block)
    city = arguments["city"]?.as?(String) || "somewhere"
    [M::TextBlock.new(%({"city":"#{city}","temp_c":18,"conditions":"light rain"})).as(M::Block)]
  end
end

private def toolbox : Liaison::Toolbox
  Liaison::Toolbox.new([Weather.new] of Liaison::Function)
end

# Tools declared, reasoning off. The second half matters for the handoff
# example: Ollama reasons on every endpoint and cannot mint an Anthropic thought
# signature, so a reply carrying both a tool call and a reasoning block degrades
# on the way into an Anthropic request. What is under test here is the call and
# its result surviving, so the reasoning is switched off rather than asserted
# around. `handoff_spec.cr` covers the loss itself.
private def armed(box : Liaison::Toolbox) : Liaison::Options
  Liaison::Options.new(tools: box.tools, reasoning: Liaison::Reasoning::Off.new)
end

private def ollama : Liaison::Server
  Liaison::Server.new("ollama", "http://localhost:11434")
end

private def client(protocol : Liaison::ProtocolKind) : Liaison::Client
  Liaison::Client.new(Liaison::Provider.for(ollama, protocol))
end

private def asked : M::Session
  session = M::Session.new("Use the supplied tools when they apply.")
  session << M::Message.user("What is the weather in Paris? Use the get_weather tool.")
  session
end

describe "a turn that uses a Toolbox" do
  it "declares, dispatches, and is answered" do
    # The whole loop, once. `#dispatch` returning nil is the exit condition, so
    # the second pass ending the loop is itself the assertion that the model
    # accepted what we sent it: a rejected result comes back as another call or
    # an error, not as prose.
    Wiretap.intercept(TOOL_TURN) do
      box = toolbox
      session = asked

      first, report = client(Liaison::ProtocolKind::ChatCompletions)
        .send(session, MODEL, options: armed(box))
      report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      session << first

      calls = first.content.select(M::ToolCallBlock)
      calls.size.should eq 1
      calls.first.name.should eq "get_weather"

      results = box.dispatch(first).should_not be_nil
      results.role.should eq M::Role::User
      results.content.select(M::ToolResultBlock).first.call_id.should eq calls.first.call_id
      session << results

      second, _ = client(Liaison::ProtocolKind::ChatCompletions)
        .send(session, MODEL, options: armed(box))
      session << second

      second.content.select(M::TextBlock).should_not be_empty
      box.dispatch(second).should be_nil
      M::Repair.sendable?(session).should be_true
    end
  end

  it "keeps the call paired to its result across a file" do
    # `call_id` is minted by MPSH and translated per provider, so the pairing is
    # the field most likely to be lost by a format that forgot it. The archive
    # is also where `Conformance.compare` stops helping: it walks what a wire
    # can carry, and the pairing it checks is the provider's, not ours.
    SavedSession.in_a_file do |path|
      Wiretap.intercept(TOOL_TURN) do
        box = toolbox
        session = asked

        first, _ = client(Liaison::ProtocolKind::ChatCompletions)
          .send(session, MODEL, options: armed(box))
        session << first
        session << box.dispatch(first).should_not be_nil

        reloaded = SavedSession.round_trip(session, path)
        call = reloaded.messages[1].content.select(M::ToolCallBlock).first
        result = reloaded.messages[2].content.select(M::ToolResultBlock).first

        result.call_id.should eq call.call_id
        M::Repair.sendable?(reloaded).should be_true
      end
    end
  end

  it "hands a completed tool exchange to another protocol" do
    # A call minted on Chat Completions, a result we produced for it, and an
    # Anthropic endpoint asked to make sense of both. This is the handoff claim
    # at its least forgiving: a protocol will reject a call whose result it
    # cannot pair, so acceptance here is a real answer rather than a shrug.
    SavedSession.in_a_file do |path|
      Wiretap.intercept(TOOL_TURN) do
        box = toolbox
        session = asked

        first, _ = client(Liaison::ProtocolKind::ChatCompletions)
          .send(session, MODEL, options: armed(box))
        session << first
        session << box.dispatch(first).should_not be_nil

        resumed = SavedSession.round_trip(session, path)

        Wiretap.intercept(TOOL_HANDOFF) do
          reply, report = client(Liaison::ProtocolKind::Anthropic)
            .send(resumed, MODEL, options: armed(box))

          report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
          reply.content.select(M::TextBlock).should_not be_empty
        end
      end
    end
  end
end
