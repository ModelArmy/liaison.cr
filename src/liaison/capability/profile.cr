require "../mpsh/block"

module Liaison::Capability
  # How a protocol carries a binary block that it does support.
  enum BinaryForm
    Native  # separate media type + base64 -> Exact
    DataUri # fused into a `data:` URI -> Restructured
    None    # not carried at all
  end

  enum ToolResultForm
    Blocks   # nested content list, images welcome (Anthropic)
    TextOnly # string output only (both OpenAI protocols)
    None
  end

  enum ToolCallForm
    Block # native content block (Anthropic, Gemini)
    Field # hoisted onto the message or emitted as an item (OpenAI)
    None
  end

  # Where a reasoning item can live in a *request*, which is a different
  # question from whether a response returns one.
  enum ReasoningForm
    Block # a content block (Anthropic)
    Item  # an item in the input array (Responses)
    Field # a message-level field, e.g. `reasoning_content`
    None  # no home at all; replaying reasoning is impossible
  end

  # Which unit a request may use to ask for reasoning. Independent of
  # `ReasoningForm`, which says where a past reasoning item can be replayed: a
  # profile may carry no past reasoning yet accept `reasoning_effort`.
  #
  # `Either` means the protocol spells both units and rejects being given both.
  # Which one a deployment wants depends on the model (Claude 4.7 rejects a
  # budget; Claude Sonnet 4.5 has no effort parameter), so `Catalog` narrows
  # it per call.
  enum ReasoningUnit
    None   # no control at all; a request cannot ask
    Effort # a named rung
    Budget # a token count
    Either # both are spelled; the deployment decides which
  end

  enum SystemPlacement
    InMessages   # Chat Completions `role: system` / `developer`
    Instructions # Responses API
    Parameter    # Anthropic `system`
    Structured   # Gemini `systemInstruction.parts`
  end

  # A protocol's declaration of what it can express. Values are a starting
  # point, confirmed against each vendor's live docs rather than trusted.
  # Media support is declared per media type: a model may take PNG and not
  # WEBP.
  struct Profile
    # Names the protocol, e.g. `openai.chat_completions`: a wire shape, never an
    # endpoint, since Ollama, LM Studio and vLLM all serve one protocol.
    getter provider : String

    # Names whoever issues opaque data that must be echoed back, e.g. `openai`.
    # Separate from `provider` because both OpenAI protocols replay the same
    # vendor's data. Defaults to `provider`.
    getter metadata_key : String
    getter accepted_media : Hash(MPSH::BlockKind, Set(String))
    getter binary_form : BinaryForm
    getter tool_calls : ToolCallForm
    getter tool_results : ToolResultForm
    getter reasoning : ReasoningForm
    # What a request may ask of the model's reasoning; `reasoning` above
    # governs replaying a past item.
    getter reasoning_unit : ReasoningUnit
    # Whether the protocol has provider-run tools at all. Whether a given call
    # is this provider's own is decided per block, by `Resolver#own?`.
    getter? server_executed : Bool
    getter? refusal_channel : Bool
    getter? can_synthesize_user_message : Bool
    getter? alternation_required : Bool
    getter? first_message_must_be_user : Bool
    getter system_placement : SystemPlacement
    getter? string_shorthand : Bool
    # Whether this protocol's reasoning blocks are valid only with a payload the
    # vendor issued, such as a signature. True only for Anthropic, where a
    # `thinking` block without `signature` fails the request schema (recorded
    # in `spec/live/anthropic_spec.cr`). `Resolver` checks it ahead of its rule
    # that empty metadata is portable.
    getter? reasoning_signature_required : Bool

    # Whether tool calls are valid only with a vendor-issued payload. Separate
    # from `reasoning_signature_required` because Gemini requires one on a
    # `functionCall` and not on a `thought`.
    #
    # False on every protocol, Gemini included, and switched on per model by
    # `Catalog::SIGNED_TOOL_CALLS`: Gemini 3 requires it and 2.5 does not.
    # Declared protocol-wide, it would drop every tool call sent to a 2.5
    # deployment.
    getter? tool_call_signature_required : Bool

    def initialize(
      @provider : String,
      metadata_key : String? = nil,
      @accepted_media : Hash(MPSH::BlockKind, Set(String)) = {} of MPSH::BlockKind => Set(String),
      @binary_form : BinaryForm = BinaryForm::Native,
      @tool_calls : ToolCallForm = ToolCallForm::Block,
      @tool_results : ToolResultForm = ToolResultForm::Blocks,
      @reasoning : ReasoningForm = ReasoningForm::Block,
      @reasoning_unit : ReasoningUnit = ReasoningUnit::None,
      @server_executed : Bool = false,
      @refusal_channel : Bool = false,
      @can_synthesize_user_message : Bool = true,
      @alternation_required : Bool = false,
      @first_message_must_be_user : Bool = false,
      @system_placement : SystemPlacement = SystemPlacement::InMessages,
      @string_shorthand : Bool = true,
      @reasoning_signature_required : Bool = false,
      @tool_call_signature_required : Bool = false,
    )
      @metadata_key = metadata_key || @provider
    end

    def accepts?(kind : MPSH::BlockKind, media_type : String) : Bool
      (set = @accepted_media[kind]?) ? set.includes?(media_type) : false
    end

    # The same profile with another `metadata_key`, for a deployment that does
    # not honour the vendor's opaque data. `Resolver#own?` compares block
    # metadata against the key, so foreign signatures stop counting as native
    # and degrade.
    def with_metadata_key(metadata_key : String) : Profile
      Profile.new(
        @provider,
        metadata_key: metadata_key,
        accepted_media: @accepted_media,
        binary_form: @binary_form,
        tool_calls: @tool_calls,
        tool_results: @tool_results,
        reasoning: @reasoning,
        reasoning_unit: @reasoning_unit,
        server_executed: @server_executed,
        refusal_channel: @refusal_channel,
        can_synthesize_user_message: @can_synthesize_user_message,
        alternation_required: @alternation_required,
        first_message_must_be_user: @first_message_must_be_user,
        system_placement: @system_placement,
        string_shorthand: @string_shorthand,
        reasoning_signature_required: @reasoning_signature_required,
        tool_call_signature_required: @tool_call_signature_required)
    end

    # The same profile with `Either` resolved to `Effort` or `Budget`. Raises
    # `ArgumentError` for anything else: widening `None`, or swapping one
    # declared unit for the other, would claim a control the wire lacks, which
    # fails as a 400 rather than a recorded loss.
    def with_reasoning_unit(unit : ReasoningUnit) : Profile
      return self if unit == @reasoning_unit

      unless @reasoning_unit.either? && (unit.effort? || unit.budget?)
        raise ArgumentError.new(
          "#{@provider}: cannot narrow reasoning unit #{@reasoning_unit} to #{unit}; " \
          "only Either may be narrowed, and only to Effort or Budget")
      end

      Profile.new(
        @provider,
        metadata_key: @metadata_key,
        accepted_media: @accepted_media,
        binary_form: @binary_form,
        tool_calls: @tool_calls,
        tool_results: @tool_results,
        reasoning: @reasoning,
        reasoning_unit: unit,
        server_executed: @server_executed,
        refusal_channel: @refusal_channel,
        can_synthesize_user_message: @can_synthesize_user_message,
        alternation_required: @alternation_required,
        first_message_must_be_user: @first_message_must_be_user,
        system_placement: @system_placement,
        string_shorthand: @string_shorthand,
        reasoning_signature_required: @reasoning_signature_required,
        tool_call_signature_required: @tool_call_signature_required)
    end

    # The same profile, requiring signed tool calls. This narrows: a call that
    # would have mapped `Exact` now has a condition to meet. Raises
    # `ArgumentError` when asked to waive a requirement the profile already
    # has, since a catalog may add one, never remove it.
    def with_tool_call_signature_required(required : Bool) : Profile
      return self if required == @tool_call_signature_required

      unless required
        raise ArgumentError.new(
          "#{@provider}: cannot waive tool_call_signature_required; " \
          "the catalog may add the requirement, never remove it")
      end

      Profile.new(
        @provider,
        metadata_key: @metadata_key,
        accepted_media: @accepted_media,
        binary_form: @binary_form,
        tool_calls: @tool_calls,
        tool_results: @tool_results,
        reasoning: @reasoning,
        reasoning_unit: @reasoning_unit,
        server_executed: @server_executed,
        refusal_channel: @refusal_channel,
        can_synthesize_user_message: @can_synthesize_user_message,
        alternation_required: @alternation_required,
        first_message_must_be_user: @first_message_must_be_user,
        system_placement: @system_placement,
        string_shorthand: @string_shorthand,
        reasoning_signature_required: @reasoning_signature_required,
        tool_call_signature_required: true)
    end
  end
end
