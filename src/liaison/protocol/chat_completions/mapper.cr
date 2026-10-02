require "./wire/request"
require "../../options"
require "./capabilities"
require "../../capability/resolver"
require "../../capability/policy"
require "../../capability/retention"
require "../../capability/reasoning_control"
require "../../capability/carrier"
require "../../mpsh/session"
require "../../mpsh/translation"

module Liaison::Protocol::ChatCompletions
  # Text left where content was lifted out of a tool result: a protocol
  # marker that export matches exactly, not a note to a human. The single
  # definition is `Capability::Carrier::PLACEHOLDER`.
  COMPENSATION_PLACEHOLDER = Capability::Carrier::PLACEHOLDER

  # MPSH view in, request body out. Every outcome passes through
  # `Report#record`, where policy is enforced.
  class Mapper
    getter profile : Capability::Profile
    getter calls : MPSH::CallIdTable
    getter max_tokens_field : Wire::MaxTokensField

    def initialize(@profile : Capability::Profile = PROFILE,
                   @calls : MPSH::CallIdTable = MPSH::CallIdTable.new(NAME),
                   @max_tokens_field : Wire::MaxTokensField = Wire::MaxTokensField::MaxTokens)
    end

    def map(session : MPSH::Session, model : String,
            policy : Capability::Policy = Capability::Policy::Compensating,
            retention : Capability::ReasoningRetention = Capability::ReasoningRetention::All,
            options : Options = Options.new) : {Wire::Request, Capability::Report}
      report = Capability::Report.new(NAME, policy)
      plan = Capability::Retention.plan(session.messages, retention)
      report.reasoning_dropped = plan.dropped

      wire = [] of Wire::Message
      # Compensation carriers are buffered; see `flush_compensation`.
      pending = [] of Wire::Part

      if prompt = session.system_prompt
        # The system prompt becomes a message: `Restructured`, not a loss.
        report.record(Capability::Structural.outcome(
          Capability::Structural::Adaptation::MoveSystemPrompt), "system prompt to messages array")
        wire << Wire::Message.new("system", prompt)
      end

      session.messages.each_with_index do |message, index|
        case message.role
        in MPSH::Role::User      then map_user(message, index, wire, report, pending)
        in MPSH::Role::Assistant then map_assistant(message, index, wire, report, plan, pending)
        end
      end

      flush_compensation(wire, pending, report)
      {Wire::Request.new(model, wire, declarations(options), options.max_output_tokens,
        reasoning_effort(options, report), @max_tokens_field,
        options.tool_choice.try(&.wire_name)), report}
    end

    # The named rung, lowercase, or nothing. A token budget is bucketed to a
    # rung and reported `Degraded`. `Off` is spelled `none`.
    private def reasoning_effort(options : Options,
                                 report : Capability::Report) : String?
      request = options.reasoning
      return unless request

      rendering, outcome = Capability::ReasoningControl.resolve(request, profile.reasoning_unit)
      report.record(outcome,
        Capability::ReasoningControl.detail(request, rendering, profile.reasoning_unit))

      case rendering
      in Capability::ReasoningControl::Rendering::AsEffort
        case request
        in Reasoning::Effort then request.wire_name
        in Reasoning::Budget then request.to_effort.wire_name
        in Reasoning::Off    then "none"
        end
      in Capability::ReasoningControl::Rendering::Disable
        "none"
      in Capability::ReasoningControl::Rendering::AsBudget
        nil
      in Capability::ReasoningControl::Rendering::Drop
        nil
      end
    end

    # Tool declarations from `Options`.
    private def declarations(options : Options) : Array(Wire::ToolDeclaration)
      options.tools.map do |tool|
        Wire::ToolDeclaration.new(tool.name, tool.description, tool.parameters)
      end
    end

    # Emits a buffered carrier as a synthetic user message. The rule and flush
    # points are `Capability::Carrier`'s; this supplies the message shape. The
    # `synthetic` flag lets an export in the same process discard it; one
    # reading JSON from a server recognises it by its markers.
    private def flush_compensation(wire : Array(Wire::Message),
                                   pending : Array(Wire::Part),
                                   report : Capability::Report) : Nil
      Capability::Carrier.flush(pending, report) do |parts|
        wire << Wire::Message.new("user", parts, synthetic: true)
      end
    end

    # A user message may become several wire messages: tool results split out
    # into `role: "tool"` messages, and compensation may append another.
    private def map_user(message : MPSH::Message, index : Int32,
                         wire : Array(Wire::Message), report : Capability::Report,
                         pending : Array(Wire::Part)) : Nil
      parts = [] of Wire::Part

      message.content.each do |block|
        case block
        when MPSH::ToolResultBlock
          wire << tool_result_message(block, index, report, pending)
        else
          part = render(block, index, report)
          parts << part if part
        end
      end

      return if parts.empty?

      # Genuine user content ends the run of tool messages, so a pending
      # carrier goes out first.
      flush_compensation(wire, pending, report)
      wire << Wire::Message.new("user", parts)
    end

    private def map_assistant(message : MPSH::Message, index : Int32,
                              wire : Array(Wire::Message), report : Capability::Report,
                              plan : Capability::Retention::Plan,
                              pending : Array(Wire::Part)) : Nil
      # An assistant turn closes the preceding run of tool results.
      flush_compensation(wire, pending, report)
      parts = [] of Wire::Part
      calls = [] of Wire::ToolCall
      refusal : String? = nil
      reasoning : String? = nil

      message.content.each do |block|
        case block
        in MPSH::ToolCallBlock
          rendered = tool_call(block, index, report)
          calls << rendered if rendered
        in MPSH::ReasoningBlock
          next unless plan.retain?(index)
          reasoning = reasoning_text(block, index, report)
        in MPSH::RefusalBlock
          refusal = refusal_text(block, index, report, parts)
        in MPSH::TextBlock, MPSH::ImageBlock, MPSH::AudioBlock,
           MPSH::DocumentBlock, MPSH::ToolResultBlock
          part = render(block, index, report)
          parts << part if part
        end
      end

      content = parts.empty? ? nil : parts
      return if content.nil? && calls.empty? && refusal.nil? && reasoning.nil?

      wire << Wire::Message.new("assistant", content,
        tool_calls: calls.empty? ? nil : calls,
        refusal: refusal,
        reasoning_content: reasoning)
    end

    # A tool result here is a string. Non-text content is lifted into
    # `compensation`, which goes out later in a synthesized user message.
    private def tool_result_message(block : MPSH::ToolResultBlock, index : Int32,
                                    report : Capability::Report,
                                    pending : Array(Wire::Part)) : Wire::Message
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "tool result rendered as a role:tool message",
        index, MPSH::BlockKind::ToolResult)

      text = [] of String
      block.content.each do |nested|
        case nested
        when MPSH::TextBlock
          text << nested.text
        else
          part = render(nested, index, report, Capability::Resolver::Nesting::InsideToolResult)
          if part
            pending << part
            text << COMPENSATION_PLACEHOLDER
          end
        end
      end

      Wire::Message.new("tool", text.join("\n"),
        tool_call_id: calls.provider_id(block.call_id) || block.call_id)
    end

    private def tool_call(block : MPSH::ToolCallBlock, index : Int32,
                          report : Capability::Report) : Wire::ToolCall?
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "tool call hoisted to the tool_calls field",
        index, MPSH::BlockKind::ToolCall)
      return if outcome.lossy?

      provider_id = calls.provider_id(block.call_id) || block.call_id
      calls.bind(block.call_id, provider_id)
      Wire::ToolCall.new(provider_id, block.name, block.arguments.to_json)
    end

    private def reasoning_text(block : MPSH::ReasoningBlock, index : Int32,
                               report : Capability::Report) : String?
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "reasoning carried as reasoning_content",
        index, MPSH::BlockKind::Reasoning)
      block.text
    end

    private def refusal_text(block : MPSH::RefusalBlock, index : Int32,
                             report : Capability::Report,
                             parts : Array(Wire::Part)) : String?
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "refusal", index, MPSH::BlockKind::Refusal)
      block.reason
    end

    # Returns nil where the block has no wire representation at all; the report
    # already carries why.
    private def render(block : MPSH::Block, index : Int32, report : Capability::Report,
                       nesting = Capability::Resolver::Nesting::TopLevel) : Wire::Part?
      case block
      in MPSH::TextBlock
        Wire::TextPart.new(block.text)
      in MPSH::ImageBlock, MPSH::AudioBlock, MPSH::DocumentBlock
        binary(block, index, report, nesting)
      in MPSH::ToolCallBlock, MPSH::ToolResultBlock
        nil # handled by their own paths
      in MPSH::ReasoningBlock
        nil
      in MPSH::RefusalBlock
        block.reason.try { |reason| Wire::TextPart.new(reason) }
      end
    end

    private def binary(block : MPSH::BinaryBlock, index : Int32,
                       report : Capability::Report,
                       nesting : Capability::Resolver::Nesting) : Wire::Part?
      outcome = Capability::Resolver.outcome(block, profile, nesting)
      report.record(outcome, "#{block.kind.to_s.downcase} #{block.media_type}",
        index, block.kind)

      case outcome
      when MPSH::Outcome::Degraded
        block.text_fallback.try { |text| Wire::TextPart.new(text) }
      when MPSH::Outcome::Refused
        nil # unreachable: record raises first
      else
        payload = materialize(block.payload)
        case block
        when MPSH::ImageBlock    then Wire::ImagePart.new(payload.media_type, payload.base64)
        when MPSH::AudioBlock    then Wire::AudioPart.new(payload.base64, format_of(payload.media_type))
        when MPSH::DocumentBlock then Wire::FilePart.new(payload.base64, block.name)
        end
      end
    end

    # Raises `RefusedError` for a reference payload: no blob store can be
    # supplied, so only inline payloads can be sent.
    private def materialize(payload : MPSH::Payload) : MPSH::InlinePayload
      case payload
      when MPSH::InlinePayload then payload
      else
        raise Capability::RefusedError.new(NAME,
          "reference payload #{payload.media_type} cannot be materialized: no blob store configured")
      end
    end

    private def format_of(media_type : String) : String
      media_type.split('/').last
    end
  end
end
