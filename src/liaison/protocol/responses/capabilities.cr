require "../../capability/profile"

module Liaison::Protocol::Responses
  METADATA_KEY = "openai"
  NAME         = "openai.responses"

  # The same assumptions as Chat Completions in a different surface: the
  # system prompt goes in `instructions`, and everything is an item in a flat
  # `input` array. One capability differs: reasoning is an item, which can
  # carry an opaque payload, so redacted reasoning round-trips here and
  # degrades on Chat Completions.
  #
  # Used statelessly. Server-held history (`previous_response_id`,
  # Conversations) would make the provider own the history this shard keeps
  # locally, and is still billed as full input on every call.
  PROFILE = Capability::Profile.new(
    provider: NAME,
    # Shared by both OpenAI protocols, so an encrypted reasoning item issued
    # over either replays over the other.
    metadata_key: METADATA_KEY,
    accepted_media: {
      MPSH::BlockKind::Image    => Set{"image/png", "image/jpeg", "image/gif", "image/webp"},
      MPSH::BlockKind::Audio    => Set{"audio/wav", "audio/mpeg"},
      MPSH::BlockKind::Document => Set{"application/pdf"},
    },
    binary_form: Capability::BinaryForm::DataUri,
    # `reasoning.effort`: Chat Completions' ladder, nested one level deeper.
    reasoning_unit: Capability::ReasoningUnit::Effort,
    tool_calls: Capability::ToolCallForm::Field,
    tool_results: Capability::ToolResultForm::TextOnly,
    server_executed: true,
    refusal_channel: true,
    can_synthesize_user_message: true,
    system_placement: Capability::SystemPlacement::Instructions,
    string_shorthand: true
  )
end
