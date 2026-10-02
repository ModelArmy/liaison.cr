require "../../capability/profile"
require "../../reasoning"
require "../../options"

module Liaison::Protocol::Gemini
  METADATA_KEY = "gemini"
  NAME         = "gemini"

  # A named rung rendered as a token budget, for 2.5-series deployments.
  # Google's ranges differ per model (Flash tops out below Pro), so these sit
  # inside the narrowest. `Max` is -1, which this protocol reads as dynamic
  # thinking: the model decides how much to spend.
  REASONING_BUDGETS = {
    Reasoning::Effort::Low    => 1024,
    Reasoning::Effort::Medium => 4096,
    Reasoning::Effort::High   => 16_384,
    Reasoning::Effort::XHigh  => 24_576,
    Reasoning::Effort::Max    => -1,
  }

  # Three rungs, uppercase. `xhigh` and `max` clamp to `HIGH`, and the mapper
  # records the loss.
  REASONING_LEVELS = {
    Reasoning::Effort::Low    => "LOW",
    Reasoning::Effort::Medium => "MEDIUM",
    Reasoning::Effort::High   => "HIGH",
    Reasoning::Effort::XHigh  => "HIGH",
    Reasoning::Effort::Max    => "HIGH",
  }

  # Tool-calling modes for `toolConfig.functionCallingConfig.mode`. A table,
  # not an uppercased `ToolChoice#wire_name`: the vocabularies only happen to
  # agree for these two values.
  #
  # Gemini accepts `NONE`, then disregards it once the conversation holds a
  # tool call; see `docs/protocols/GEMINI.md`.
  TOOL_MODES = {
    ToolChoice::Auto => "AUTO",
    ToolChoice::None => "NONE",
  }

  # Models that reject `thinkingBudget: 0` (`Budget 0 is invalid. This model
  # only works in thinking mode.`, recorded in `spec/live/gemini_spec.cr`), so
  # `Reasoning::Off` becomes the lowest rung, recorded as `Degraded`. A tier
  # fact: Flash on the same generation accepts 0. Exact names, added only on
  # a live rejection.
  CANNOT_DISABLE_THINKING = Set{
    "gemini-3.1-pro-preview",
  }

  # The most structurally divergent protocol: the assistant role is `model`,
  # every message is wrapped in `parts`, the model goes in the URL path, and
  # tool calls pair with results by name and order, with no identifier. The
  # widest media support of the four.
  #
  # `tool_results: TextOnly` is conservative, pending confirmation that a
  # `functionResponse` can carry inline binary data.
  PROFILE = Capability::Profile.new(
    provider: NAME,
    accepted_media: {
      MPSH::BlockKind::Image    => Set{"image/png", "image/jpeg", "image/gif", "image/webp", "image/heic"},
      MPSH::BlockKind::Audio    => Set{"audio/wav", "audio/mpeg", "audio/ogg", "audio/flac"},
      MPSH::BlockKind::Document => Set{"application/pdf"},
    },
    binary_form: Capability::BinaryForm::Native,
    # `thinkingBudget` on the 2.5 series, `thinkingLevel` on Gemini 3; both in
    # one `thinkingConfig` is a 400. `Catalog` resolves it per model.
    reasoning_unit: Capability::ReasoningUnit::Either,
    tool_calls: Capability::ToolCallForm::Block,
    tool_results: Capability::ToolResultForm::TextOnly,
    server_executed: true,
    refusal_channel: false,
    can_synthesize_user_message: true,
    system_placement: Capability::SystemPlacement::Structured,
    # `tool_call_signature_required` is left false: Gemini 3 requires signed
    # calls and 2.5 does not, so `Catalog::SIGNED_TOOL_CALLS` sets it per
    # model.
    string_shorthand: false
  )
end
