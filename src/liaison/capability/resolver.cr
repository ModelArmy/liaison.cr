require "./profile"
require "./policy"
require "../mpsh/block"

module Liaison::Capability
  # Derives a block's outcome on a protocol from that protocol's `Profile`, so
  # the matrix a caller queries and the branch a mapper takes are one fact.
  module Resolver
    extend self

    # Where a block sits changes what it may become.
    enum Nesting
      TopLevel
      InsideToolResult
      # Between a tool call and its result, within an unclosed turn.
      MidToolCall
    end

    def outcome(block : MPSH::Block, profile : Profile,
                nesting : Nesting = Nesting::TopLevel) : MPSH::Outcome
      case block
      in MPSH::TextBlock
        MPSH::Outcome::Exact
      in MPSH::ImageBlock, MPSH::AudioBlock, MPSH::DocumentBlock
        binary_outcome(block, profile, nesting)
      in MPSH::ToolCallBlock
        tool_call_outcome(block, profile)
      in MPSH::ToolResultBlock
        tool_result_outcome(block, profile)
      in MPSH::ReasoningBlock
        reasoning_outcome(block, profile, nesting)
      in MPSH::RefusalBlock
        # A past refusal is history: its text travels as text without loss. One
        # with no text has nothing to carry, which is the loss worth reporting.
        return MPSH::Outcome::Exact if profile.refusal_channel?
        block.reason ? MPSH::Outcome::Restructured : MPSH::Outcome::Degraded
      end
    end

    # Reasoning that belongs to the target is `Exact`. Foreign reasoning is
    # `Restructured`, not a loss: MPSH keeps the block and namespacing sheds
    # the payload. As `Degraded` it would make `Strict` refuse every
    # cross-provider handoff of a reasoning session. Mid-tool-call it is
    # `Refused`, since some providers require it replayed unmodified there.
    private def reasoning_outcome(block : MPSH::ReasoningBlock, profile : Profile,
                                  nesting : Nesting) : MPSH::Outcome
      # Ownership is not enough: with nowhere to put reasoning in a request,
      # nothing can be replayed.
      return degrade_or_refuse(nesting) if profile.reasoning.none?

      # Where the native form needs a vendor-issued payload, text alone will not
      # do even when `own?` holds: empty metadata is exactly what reasoning with
      # nothing to replay looks like.
      if profile.reasoning_signature_required? && !replayable?(block, profile)
        return degrade_or_refuse(nesting)
      end

      # A message-level field carries text only, and redacted reasoning has
      # none; its content is in `provider_metadata`.
      if block.redacted? && block.text.nil? && profile.reasoning.field?
        return degrade_or_refuse(nesting)
      end

      return MPSH::Outcome::Exact if own?(block, profile)
      nesting.mid_tool_call? ? MPSH::Outcome::Refused : MPSH::Outcome::Restructured
    end

    # For reasoning this wire cannot carry: a recorded loss, except mid-tool-
    # call, where some providers require the item replayed unmodified and
    # dropping it breaks the turn.
    private def degrade_or_refuse(nesting : Nesting) : MPSH::Outcome
      nesting.mid_tool_call? ? MPSH::Outcome::Refused : MPSH::Outcome::Degraded
    end

    # Whether a block belongs to the target: it carries the target's
    # `metadata_key`, or no provider metadata at all, since plain reasoning
    # text belongs to no one. A property of the block seen from a profile, not
    # of the profile. Keyed on `metadata_key` rather than `provider`, because
    # one vendor may offer two protocols.
    private def own?(block, profile : Profile) : Bool
      metadata = block.provider_metadata
      return true if metadata.empty?
      metadata.has_key?(profile.metadata_key)
    end

    # Whether a block carries a payload this vendor issued and will accept
    # back: a `signature`, `redacted_data` or `thought_signature` under the
    # profile's own `metadata_key`. A payload under another vendor's key is as
    # unusable as none, so this subsumes `own?`. One predicate over all three
    # spellings, since each lives under exactly one vendor's key.
    REPLAY_PAYLOAD_KEYS = {"signature", "redacted_data", "thought_signature"}

    private def replayable?(block : MPSH::Block, profile : Profile) : Bool
      meta = block.meta_for(profile.metadata_key)
      return false unless meta
      REPLAY_PAYLOAD_KEYS.any? { |key| meta.has_key?(key) }
    end

    private def binary_outcome(block : MPSH::BinaryBlock, profile : Profile,
                               nesting : Nesting) : MPSH::Outcome
      carriable = profile.accepts?(block.kind, block.media_type) &&
                  !profile.binary_form.none?

      if carriable && nesting.inside_tool_result?
        # Anthropic takes it natively; the OpenAI protocols cannot put binary
        # inside a tool result at all, however well they take it elsewhere.
        return profile.tool_results.blocks? ? native_or_restructured(profile) : compensate_or_fall_back(block, profile)
      end

      return native_or_restructured(profile) if carriable
      block.text_fallback ? MPSH::Outcome::Degraded : MPSH::Outcome::Refused
    end

    private def native_or_restructured(profile : Profile) : MPSH::Outcome
      profile.binary_form.native? ? MPSH::Outcome::Exact : MPSH::Outcome::Restructured
    end

    private def compensate_or_fall_back(block : MPSH::BinaryBlock, profile : Profile) : MPSH::Outcome
      # A tool returning a screenshot, on a protocol whose tool results are
      # text only: a placeholder result plus a synthesized user message
      # carrying the image.
      return MPSH::Outcome::Compensated if profile.can_synthesize_user_message? &&
                                           profile.accepts?(block.kind, block.media_type)
      block.text_fallback ? MPSH::Outcome::Degraded : MPSH::Outcome::Refused
    end

    private def tool_call_outcome(block : MPSH::ToolCallBlock, profile : Profile) : MPSH::Outcome
      return MPSH::Outcome::Refused if profile.tool_calls.none?

      if block.server_executed?
        # Exact only on the protocol of the provider that ran it. Elsewhere the
        # result survives as conversation and the tool framing does not.
        return MPSH::Outcome::Exact if profile.server_executed? && own?(block, profile)
        return MPSH::Outcome::Degraded
      end

      # A protocol that authenticates its tool calls cannot accept one it did
      # not issue: `reasoning_signature_required`, one block kind over.
      #
      # `Degraded`, not `Refused`: the mapper drops the call and records the
      # loss, which a `Strict` caller escalates by policy, where `Refused`
      # would fail every cross-protocol handoff carrying a tool call. The
      # call's result is not dropped with it.
      if profile.tool_call_signature_required? && !replayable?(block, profile)
        return MPSH::Outcome::Degraded
      end

      profile.tool_calls.block? ? MPSH::Outcome::Exact : MPSH::Outcome::Restructured
    end

    private def tool_result_outcome(block : MPSH::ToolResultBlock, profile : Profile) : MPSH::Outcome
      return MPSH::Outcome::Refused if profile.tool_results.none?
      if block.server_executed?
        return MPSH::Outcome::Degraded unless profile.server_executed? && own?(block, profile)
      end

      worst = profile.tool_results.blocks? ? MPSH::Outcome::Exact : MPSH::Outcome::Restructured
      block.content.each do |nested|
        nested_outcome = outcome(nested, profile, Nesting::InsideToolResult)
        worst = nested_outcome if nested_outcome > worst
      end
      worst
    end

    # The outcome of each block in a representative set, labelled by kind and
    # media type, so a caller can see in advance what a profile will lose.
    def matrix(profile : Profile, blocks : Array(MPSH::Block)) : Hash(String, MPSH::Outcome)
      blocks.each_with_object({} of String => MPSH::Outcome) do |block, acc|
        label = case block
                in MPSH::ImageBlock, MPSH::AudioBlock, MPSH::DocumentBlock
                  "#{block.kind}(#{block.media_type})"
                in MPSH::ToolResultBlock
                  block.text_only? ? "ToolResult(text)" : "ToolResult(mixed)"
                in MPSH::TextBlock, MPSH::ToolCallBlock, MPSH::ReasoningBlock, MPSH::RefusalBlock
                  block.kind.to_s
                end
        acc[label] = outcome(block, profile)
      end
    end
  end
end
