require "../../capability/profile"
require "../../reasoning"

module Liaison::Protocol::Anthropic
  METADATA_KEY = "anthropic"
  NAME         = "anthropic"

  # Required by the protocol, with no default. Overridable per request.
  DEFAULT_MAX_TOKENS = 4096

  # Sent as `anthropic-version` on every request, which the endpoint requires.
  # Pinned, since a new version can change the response shapes these readers
  # expect.
  API_VERSION = "2023-06-01"

  # The API rejects a smaller budget outright.
  MIN_THINKING_BUDGET = 1024

  # A named rung rendered as a token budget, for deployments that take only a
  # budget. `Restructured` rather than `Degraded`: Anthropic presents these
  # rungs itself, and the figures follow its budget guidance (start near the
  # 1,024 floor; 16,000 or more for complex work; batch processing beyond
  # 32,000).
  #
  # `Max` has no fixed number: it resolves to one under the request's output
  # cap, since a budget must leave room for the answer.
  REASONING_BUDGETS = {
    Reasoning::Effort::Low    => 1024,
    Reasoning::Effort::Medium => 4096,
    Reasoning::Effort::High   => 16_000,
    Reasoning::Effort::XHigh  => 32_000,
    Reasoning::Effort::Max    => Int32::MAX,
  }

  # The most capable target and the strictest validator. Tool results take
  # nested blocks, so a tool returning a screenshot is native here. No audio:
  # a voice note degrades to its transcript, or is refused without one.
  PROFILE = Capability::Profile.new(
    provider: NAME,
    accepted_media: {
      MPSH::BlockKind::Image    => Set{"image/png", "image/jpeg", "image/gif", "image/webp"},
      MPSH::BlockKind::Document => Set{"application/pdf"},
    },
    binary_form: Capability::BinaryForm::Native,
    # Which unit depends on the model: `thinking.budget_tokens` is the only
    # mode up to Claude Sonnet and Haiku 4.5, deprecated on 4.6 and rejected
    # from 4.7, where `output_config.effort` replaces it. `Catalog` resolves
    # it per model.
    reasoning_unit: Capability::ReasoningUnit::Either,
    tool_calls: Capability::ToolCallForm::Block,
    tool_results: Capability::ToolResultForm::Blocks,
    server_executed: true,
    refusal_channel: false,
    can_synthesize_user_message: true,
    alternation_required: true,
    first_message_must_be_user: true,
    system_placement: Capability::SystemPlacement::Parameter,
    string_shorthand: true,
    # A `thinking` block without `signature` fails the request schema,
    # wherever it came from (recorded in `spec/live/anthropic_spec.cr`).
    reasoning_signature_required: true
  )
end
