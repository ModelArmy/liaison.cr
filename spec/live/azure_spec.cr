require "../spec_helper"

# Live specs against a real Azure OpenAI resource — the deployment that
# amends `Adapter` rather than exercising it. Chat Completions and Responses
# are otherwise proven live nowhere but Ollama's compatible port
# (`docs/servers/OLLAMA.md`), which validates nothing about auth or path,
# since it ignores both. This file's job is narrow: prove
# `AzureChatCompletionsAdapter` and `AzureResponsesAdapter` build a request
# a real Azure resource accepts. It is not re-proving reasoning, tools, or
# compensation — those are protocol-level claims already covered elsewhere.
#
# **One exception, at the end of the file.** Tool choice is a protocol-level
# claim that no other suite can settle for this family: Ollama's port accepts
# the field without enforcing it, so only a real OpenAI model can show `none`
# is obeyed rather than tolerated. The same reasoning put the Anthropic
# version of that test in `anthropic_spec.cr`. It stays narrow — enforcement
# only, nothing about reasoning or compensation.
#
# **Recording.** Needs `AZURE_OPENAI_API_KEY` in the environment and
# `RECORD=1` to cut a transcript. Once committed it replays offline like
# every other live spec — CI sets no key at all, same as the Anthropic and
# Gemini suites, because the credential plays no part in matching a
# recording: Wiretap keys on method, URL and body, and headers are filtered
# before anything is written to disk.
#
# Endpoint, deployment and api-version are **not** environment-sourced,
# unlike the credential. All three are baked into the URL Wiretap matches
# against, so — like the pinned `MODEL` in `anthropic_spec.cr` and
# `gemini_spec.cr` — they have to be committed constants, not `ops` env
# values a CI run might not set. An empty-string fallback here would build a
# URL nothing was ever recorded against and fail every replay.
#
# **Model.** `gpt5.4mini` — cheapest available, and a reasoning model. Found
# live, not assumed: it rejects `max_tokens` outright and wants
# `max_completion_tokens`, OpenAI's replacement field for the reasoning-model
# line. `ChatCompletionsAdapter` still defaults to the old spelling — Ollama's
# compatible endpoint has no support for the new one, so switching the
# default would silently stop capping output there. See
# `Protocol::ChatCompletions::Wire::MaxTokensField`. This deployment states
# its need explicitly, the same way `reasoning_unit` already lets a caller
# override what a deployment name alone cannot say.
private ENDPOINT    = "https://oxaro-alpha.openai.azure.com"
private DEPLOYMENT  = "gpt5.4mini"
private API_VERSION = "2025-04-01-preview"

private def azure : Liaison::Server
  Liaison::Server.new("azure", ENDPOINT, ENV["AZURE_OPENAI_API_KEY"]?)
end

private def client(protocol : Liaison::ProtocolKind) : Liaison::Client
  Liaison::Client.new(Liaison::Provider.for_azure(azure, protocol, API_VERSION,
    max_tokens_field: protocol.chat_completions? ? Liaison::Protocol::ChatCompletions::Wire::MaxTokensField::MaxCompletionTokens : nil))
end

private CAP = Liaison::Options.new(max_output_tokens: 64)

private def weather_tool : Liaison::Tool
  Liaison::Tool.new("get_weather", "Look up the current weather in a city",
    %({"type":"object","properties":{"city":{"type":"string","description":"City name"}},"required":["city"]}))
end

private def no_calls : Liaison::Options
  Liaison::Options.new(tools: [weather_tool], max_output_tokens: 512,
    tool_choice: Liaison::ToolChoice::None)
end

# A finished tool exchange, then a question the same tool would answer. Built
# by hand rather than minted live, which this protocol family permits and
# Gemini does not: nothing here requires a call to carry a signature.
private def after_a_tool_call : M::Session
  call = M::ToolCallBlock.new("call_live_weather", "get_weather",
    M::Object{"city" => "Paris".as(M::Value)})
  session = M::Session.new("Use the supplied tools when they apply.")
  session << M::Message.user("What is the weather in Paris?")
  session << M::Message.new(M::Role::Assistant, [call.as(M::Block)])
  session << M::Message.new(M::Role::User,
    [M::ToolResultBlock.new(call.call_id,
      [M::TextBlock.new("18C, light rain").as(M::Block)]).as(M::Block)])
  session << M::Message.user("And in Berlin?")
  session
end

describe "Azure OpenAI" do
  describe "Chat Completions" do
    it "accepts a request built by AzureChatCompletionsAdapter" do
      Wiretap.intercept("azure_chat_completions_text") do
        session = M::Session.new("You are terse.")
        session << M::Message.user("Say hello in one short sentence.")

        reply, report = client(Liaison::ProtocolKind::ChatCompletions)
          .send(session, DEPLOYMENT, options: CAP)

        reply.content.should_not be_empty
        # Not `Exact`: a system prompt is unconditionally Restructured on this
        # protocol too, by design — MPSH holds it as a session field, and
        # turning it into a message is a restructuring regardless of the
        # protocol calling that placement native. Pinned by
        # `spec/conformance/layer_spec.cr` ("Any session with a system prompt
        # is Restructured here, so Exact was never on offer"). What this call
        # actually proves is narrower and is what's asserted: nothing refused.
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end
  end

  describe "Responses" do
    it "accepts a request built by AzureResponsesAdapter" do
      Wiretap.intercept("azure_responses_text") do
        session = M::Session.new("You are terse.")
        session << M::Message.user("Say hello in one short sentence.")

        reply, report = client(Liaison::ProtocolKind::Responses)
          .send(session, DEPLOYMENT, options: CAP)

        reply.content.should_not be_empty
        # Not `Exact`: a system prompt always reports Restructured here — it
        # moves to the top-level `instructions` field on every call, not just
        # this one. See RESPONSES.md, "Declared capabilities". What this call
        # actually proves is narrower and is what's asserted: nothing refused.
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end
  end

  # The one place this file goes past its stated remit, and deliberately.
  #
  # Everywhere else here proves auth and path and leaves protocol claims to
  # the suites that own them. Tool choice cannot be left to those, because the
  # only other server speaking Chat Completions and Responses is Ollama's
  # compatible port — which accepts more than it enforces, so a reply with no
  # tool call there is equally consistent with the field being honoured and
  # with a model that did not fancy a tool. Proving `none` is *obeyed* on this
  # protocol family needs a real OpenAI model, and this is the only file with
  # one.
  #
  # Same arrangement as `spec/live/anthropic_spec.cr`: a completed exchange for
  # one city, then a question about a second, with the tool still declared.
  # Under `auto` that is a call.
  #
  # Enforcement is the assertion; content is not. Anthropic answered this
  # arrangement with an empty turn — `None` guarantees no call, not an answer —
  # so prose is not something to require here. The cap is deliberately larger
  # than `CAP` above: this is a reasoning model, and 64 tokens is a budget
  # thinking alone can exhaust, which would produce an empty reply for reasons
  # having nothing to do with tool choice.
  describe "a turn that may not call a tool" do
    it "withholds the call over Chat Completions" do
      Wiretap.intercept("azure_tool_choice_none_chat_completions") do
        reply, report = client(Liaison::ProtocolKind::ChatCompletions)
          .send(after_a_tool_call, DEPLOYMENT, options: no_calls)

        reply.content.select(M::ToolCallBlock).should be_empty
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end

    it "withholds the call over the Responses API" do
      Wiretap.intercept("azure_tool_choice_none_responses") do
        reply, report = client(Liaison::ProtocolKind::Responses)
          .send(after_a_tool_call, DEPLOYMENT, options: no_calls)

        reply.content.select(M::ToolCallBlock).should be_empty
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end
  end
end
