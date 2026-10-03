require "./wire/request"
require "../../options"
require "./capabilities"
require "../../capability/resolver"
require "../../capability/policy"
require "../../capability/retention"
require "../../capability/reasoning_control"
require "../../capability/structural"
require "../../capability/carrier"
require "../../mpsh/session"
require "../../mpsh/translation"

module Liaison::Protocol::Gemini
  # The protocol marker left where content was lifted out of a tool result;
  # one definition, in `Capability::Carrier`.
  COMPENSATION_PLACEHOLDER = Capability::Carrier::PLACEHOLDER

  # MPSH view in, request body out. Roles are renamed and everything is
  # wrapped in `parts`. The wire has no field for a call identifier, so each
  # call is bound in the `CallIdTable` as `name#ordinal`, which export uses to
  # pair responses with calls.
  class Mapper
    getter profile : Capability::Profile
    getter calls : MPSH::CallIdTable

    def initialize(@profile : Capability::Profile = PROFILE,
                   @calls : MPSH::CallIdTable = MPSH::CallIdTable.new(NAME))
    end

    def map(session : MPSH::Session, model : String,
            policy : Capability::Policy = Capability::Policy::Compensating,
            retention : Capability::ReasoningRetention = Capability::ReasoningRetention::All,
            options : Options = Options.new) : {Wire::Request, Capability::Report}
      report = Capability::Report.new(NAME, policy)
      plan = Capability::Retention.plan(session.messages, retention)
      report.reasoning_dropped = plan.dropped

      if session.system_prompt
        report.record(Capability::Structural.outcome(
          Capability::Structural::Adaptation::MoveSystemPrompt),
          "system prompt to systemInstruction")
      end

      contents = [] of Wire::Content
      pending = [] of Wire::Part
      # Calls so far per function name; with the name, the ordinal is the
      # identifier.
      ordinals = Hash(String, Int32).new(0)

      session.messages.each_with_index do |message, index|
        parts = parts_for(message, index, report, plan, pending, ordinals)
        next if parts.empty?

        # Anything that is not a tool response ends the run, a model turn
        # included, so a pending carrier goes out first.
        unless parts.any?(Wire::FunctionResponsePart)
          flush_compensation(contents, pending, report)
        end

        contents << Wire::Content.new(role_of(message), parts)
      end

      flush_compensation(contents, pending, report)
      budget, level = reasoning(options, model, report)

      {Wire::Request.new(model, contents, session.system_prompt, declarations(options),
        options.max_output_tokens, thinking_budget: budget, thinking_level: level,
        tool_mode: options.tool_choice.try { |choice| TOOL_MODES[choice] }), report}
    end

    # The thinking budget or level; at most one, since both in one
    # `thinkingConfig` is a 400 and the unit was resolved before mapping. The
    # budget is not clamped against `maxOutputTokens`: the protocol documents
    # no relationship between them.
    private def reasoning(options : Options, model : String,
                          report : Capability::Report) : {Int32?, String?}
      request = options.reasoning
      return {nil, nil} unless request

      unit = profile.reasoning_unit
      rendering, outcome = Capability::ReasoningControl.resolve(request, unit)

      # These models reject `thinkingBudget: 0`, which is how `Disable` is
      # rendered, so the lowest rung is sent instead and recorded as
      # `Degraded`: the caller asked for no thinking and gets some.
      if rendering.disable? && CANNOT_DISABLE_THINKING.includes?(model)
        report.record(MPSH::Outcome::Degraded,
          "reasoning control: reasoning off not supported on #{model}, sent as the lowest rung instead")
        return {nil, REASONING_LEVELS[Reasoning::Effort::Low]}
      end

      report.record(outcome, Capability::ReasoningControl.detail(request, rendering, unit))

      case rendering
      in Capability::ReasoningControl::Rendering::AsEffort
        {nil, level_for(request, report)}
      in Capability::ReasoningControl::Rendering::AsBudget
        budget = case request
                 in Reasoning::Effort then REASONING_BUDGETS[request]
                 in Reasoning::Budget then request.tokens
                 in Reasoning::Off    then 0
                 end
        {budget, nil}
      in Capability::ReasoningControl::Rendering::Disable
        {0, nil}
      in Capability::ReasoningControl::Rendering::Drop
        {nil, nil}
      end
    end

    # Three rungs where the caller has five; clamping down is recorded.
    private def level_for(request : Reasoning::Request,
                          report : Capability::Report) : String?
      asked = case request
              in Reasoning::Effort then request
              in Reasoning::Budget then request.to_effort
              in Reasoning::Off    then return
              end

      if asked.x_high? || asked.max?
        report.record(MPSH::Outcome::Degraded,
          "reasoning control: #{asked.wire_name} clamped to the highest rung this protocol spells")
      end
      REASONING_LEVELS[asked]
    end

    # Tool declarations from `Options`.
    private def declarations(options : Options) : Array(Wire::ToolDeclaration)
      options.tools.map do |tool|
        Wire::ToolDeclaration.new(tool.name, tool.description, tool.parameters)
      end
    end

    # `model`, not `assistant`.
    private def role_of(message : MPSH::Message) : String
      message.role.user? ? "user" : "model"
    end

    # Emits a buffered carrier as a user content. The rule and flush points
    # are `Capability::Carrier`'s.
    private def flush_compensation(contents : Array(Wire::Content),
                                   pending : Array(Wire::Part),
                                   report : Capability::Report) : Nil
      Capability::Carrier.flush(pending, report) do |parts|
        contents << Wire::Content.new("user", parts, synthetic: true)
      end
    end

    private def parts_for(message : MPSH::Message, index : Int32,
                          report : Capability::Report,
                          plan : Capability::Retention::Plan,
                          pending : Array(Wire::Part),
                          ordinals : Hash(String, Int32)) : Array(Wire::Part)
      parts = [] of Wire::Part

      message.content.each do |block|
        case block
        in MPSH::ReasoningBlock
          next unless plan.retain?(index)
          rendered = thought(block, index, report)
          parts << rendered if rendered
        in MPSH::ToolCallBlock
          rendered = function_call(block, index, report, ordinals)
          parts << rendered if rendered
        in MPSH::ToolResultBlock
          rendered = function_response(block, index, report, pending)
          parts << rendered if rendered
        in MPSH::RefusalBlock
          outcome = Capability::Resolver.outcome(block, profile)
          report.record(outcome, "refusal carried as text", index, MPSH::BlockKind::Refusal)
          block.reason.try { |reason| parts << Wire::TextPart.new(reason) }
        in MPSH::TextBlock, MPSH::ImageBlock, MPSH::AudioBlock, MPSH::DocumentBlock
          rendered = render(block, index, report)
          parts << rendered if rendered
        end
      end

      parts
    end

    # Records `name#ordinal` against the MPSH id, which is the only pairing
    # information that survives to the wire.
    private def function_call(block : MPSH::ToolCallBlock, index : Int32,
                              report : Capability::Report,
                              ordinals : Hash(String, Int32)) : Wire::Part?
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "tool call as a functionCall part", index, MPSH::BlockKind::ToolCall)
      return if outcome.lossy?

      ordinal = ordinals[block.name]
      ordinals[block.name] = ordinal + 1
      calls.bind(block.call_id, calls.positional_key(block.name, ordinal))

      # The signature is replayed when present. An unsigned call reaches here
      # only where none is required: on Gemini 3, `Resolver` degrades it
      # first, through `Catalog::SIGNED_TOOL_CALLS`.
      signature = block.meta_for(profile.metadata_key).try(&.["thought_signature"]?).try(&.as?(String))
      Wire::FunctionCallPart.new(block.name, block.arguments.to_json, signature)
    end

    # A response names the function it answers, recovered from the
    # translation table, or `unknown_function` when its call was not mapped.
    private def function_response(block : MPSH::ToolResultBlock, index : Int32,
                                  report : Capability::Report,
                                  pending : Array(Wire::Part)) : Wire::Part?
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "tool result as a functionResponse part",
        index, MPSH::BlockKind::ToolResult)
      return if outcome.lossy?

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

      Wire::FunctionResponsePart.new(function_name(block), {output: text.join("\n")}.to_json)
    end

    private def function_name(block : MPSH::ToolResultBlock) : String
      key = calls.provider_id(block.call_id)
      key ? key.rpartition('#')[0] : "unknown_function"
    end

    private def thought(block : MPSH::ReasoningBlock, index : Int32,
                        report : Capability::Report) : Wire::Part?
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "reasoning as a thought part", index, MPSH::BlockKind::Reasoning)
      return if outcome.lossy?

      meta = block.meta_for(profile.metadata_key)
      Wire::ThoughtPart.new(block.text,
        signature: meta.try(&.["thought_signature"]?).try(&.as?(String)))
    end

    private def render(block : MPSH::Block, index : Int32, report : Capability::Report,
                       nesting = Capability::Resolver::Nesting::TopLevel) : Wire::Part?
      case block
      in MPSH::TextBlock
        Wire::TextPart.new(block.text)
      in MPSH::ImageBlock, MPSH::AudioBlock, MPSH::DocumentBlock
        binary(block, index, report, nesting)
      in MPSH::ToolCallBlock, MPSH::ToolResultBlock, MPSH::ReasoningBlock, MPSH::RefusalBlock
        nil
      end
    end

    private def binary(block : MPSH::BinaryBlock, index : Int32,
                       report : Capability::Report,
                       nesting : Capability::Resolver::Nesting) : Wire::Part?
      outcome = Capability::Resolver.outcome(block, profile, nesting)
      report.record(outcome, "#{block.kind.to_s.downcase} #{block.media_type}", index, block.kind)

      case outcome
      when MPSH::Outcome::Degraded
        block.text_fallback.try { |text| Wire::TextPart.new(text) }
      when MPSH::Outcome::Refused
        nil
      else
        payload = materialize(block.payload)
        Wire::InlineDataPart.new(payload.media_type, payload.base64)
      end
    end

    private def materialize(payload : MPSH::Payload) : MPSH::InlinePayload
      case payload
      when MPSH::InlinePayload then payload
      else
        raise Capability::RefusedError.new(NAME,
          "reference payload #{payload.media_type} cannot be materialized: no blob store configured")
      end
    end
  end
end
