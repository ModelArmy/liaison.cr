require "../../capability/profile"

module Liaison::Protocol::ChatCompletions
  METADATA_KEY = "openai"
  NAME         = "openai.chat_completions"

  # Declared capabilities, confirmed against provider docs and expected to
  # drift; re-check them first when something behaves oddly. Binary content
  # is fused into a `data:` URI, and a tool result is a string, so an
  # image-returning tool needs compensation.
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
    tool_calls: Capability::ToolCallForm::Field,
    tool_results: Capability::ToolResultForm::TextOnly,
    # `reasoning_content` is not in OpenAI's specification but is served by
    # vLLM, Ollama and others, so it is declared `Field`. A profile for
    # OpenAI's own endpoint would declare `None`, and reasoning would degrade
    # rather than replay.
    reasoning: Capability::ReasoningForm::Field,
    # `reasoning_effort` asks the model to think; `reasoning` above replays
    # thinking it did. Independent: a strict OpenAI profile would declare
    # `ReasoningForm::None` and still `Effort`. Accepted rungs vary by model,
    # but the unit never does, so the catalog has nothing to narrow.
    reasoning_unit: Capability::ReasoningUnit::Effort,
    server_executed: false,
    refusal_channel: true,
    can_synthesize_user_message: true,
    alternation_required: false,
    first_message_must_be_user: false,
    system_placement: Capability::SystemPlacement::InMessages,
    string_shorthand: true
  )
end
