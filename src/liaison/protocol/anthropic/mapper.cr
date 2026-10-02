require "./wire/request"
require "../../options"
require "./capabilities"
require "../../capability/resolver"
require "../../capability/policy"
require "../../capability/retention"
require "../../capability/reasoning_control"
require "../../capability/structural"
require "../../mpsh/session"
require "../../mpsh/translation"

module Liaison::Protocol::Anthropic
  # Text of the user message prepended when history opens with an assistant
  # turn. Export recognises the scaffolding by this exact text.
  FIRST_USER_PLACEHOLDER = "[liaison: continuing a conversation that began earlier]"

  # MPSH view in, request body out.
  #
  # Roles must alternate and the first message must be the user's, so a
  # sequence pass after rendering drops empty messages, prepends a
  # placeholder user turn, and merges consecutive same-role messages, each
  # recorded as a structural adaptation.
  class Mapper
    getter profile : Capability::Profile
    getter calls : MPSH::CallIdTable

    def initialize(@profile : Capability::Profile = PROFILE,
                   @calls : MPSH::CallIdTable = MPSH::CallIdTable.new(NAME))
    end

    def map(session : MPSH::Session, model : String,
            policy : Capability::Policy = Capability::Policy::Compensating,
            retention : Capability::ReasoningRetention = Capability::ReasoningRetention::All,
            max_tokens : Int32 = DEFAULT_MAX_TOKENS,
            options : Options = Options.new) : {Wire::Request, Capability::Report}
      report = Capability::Report.new(NAME, policy)
      plan = Capability::Retention.plan(session.messages, retention)
      report.reasoning_dropped = plan.dropped

      if session.system_prompt
        report.record(Capability::Structural.outcome(
          Capability::Structural::Adaptation::MoveSystemPrompt), "system prompt to the system parameter")
      end

      rendered = session.messages.map_with_index do |message, index|
        Wire::Message.new(role_of(message), blocks_for(message, index, report, plan))
      end

      messages = normalize(rendered, report)
      # `options.max_output_tokens` wins; the positional `max_tokens` is the
      # fallback this protocol requires.
      cap = options.max_output_tokens || max_tokens
      budget, effort, disabled = reasoning(options, cap, report)

      {Wire::Request.new(model, messages, cap,
        session.system_prompt, declarations(options),
        thinking_budget: budget, effort: effort, thinking_disabled: disabled,
        tool_choice: options.tool_choice.try(&.wire_name)), report}
    end

    # The thinking budget, the effort rung, and whether thinking is off. At
    # most one is set, since the unit was resolved before mapping.
    private def reasoning(options : Options, cap : Int32,
                          report : Capability::Report) : {Int32?, String?, Bool}
      request = options.reasoning
      return {nil, nil, false} unless request

      unit = profile.reasoning_unit
      rendering, outcome = Capability::ReasoningControl.resolve(request, unit)
      report.record(outcome, Capability::ReasoningControl.detail(request, rendering, unit))

      case rendering
      in Capability::ReasoningControl::Rendering::AsEffort
        level = case request
                in Reasoning::Effort then request.wire_name
                in Reasoning::Budget then request.to_effort.wire_name
                in Reasoning::Off    then nil
                end
        {nil, level, false}
      in Capability::ReasoningControl::Rendering::AsBudget
        {clamped_budget(request, cap, report), nil, false}
      in Capability::ReasoningControl::Rendering::Disable
        {nil, nil, true}
      in Capability::ReasoningControl::Rendering::Drop
        {nil, nil, false}
      end
    end

    # The budget must be at least 1,024 and below the output cap, which it
    # shares with the answer; `Max` resolves to one under the cap.
    #
    # The caller's cap is never raised to fit a budget. Where the clamp falls
    # below the floor, no thinking is requested and the loss is recorded.
    private def clamped_budget(request : Reasoning::Request, cap : Int32,
                               report : Capability::Report) : Int32?
      wanted = case request
               in Reasoning::Effort then REASONING_BUDGETS[request]
               in Reasoning::Budget then request.tokens
               in Reasoning::Off    then return
               end

      budget = {wanted, cap - 1}.min
      return budget if budget >= MIN_THINKING_BUDGET

      report.record(MPSH::Outcome::Degraded,
        "reasoning control: a cap of #{cap} leaves no room for the " \
        "#{MIN_THINKING_BUDGET}-token minimum budget; thinking not requested")
      nil
    end

    # Tool declarations from `Options`.
    private def declarations(options : Options) : Array(Wire::ToolDeclaration)
      options.tools.map do |tool|
        Wire::ToolDeclaration.new(tool.name, tool.description, tool.parameters)
      end
    end

    private def role_of(message : MPSH::Message) : String
      message.role.user? ? "user" : "assistant"
    end

    # Drops empty messages, prepends a placeholder when history opens with the
    # assistant, and merges consecutive same-role messages. The placeholder and
    # merges are `Compensated`: export cannot undo them, so conformance expects
    # the divergence.
    private def normalize(messages : Array(Wire::Message),
                          report : Capability::Report) : Array(Wire::Message)
      # Dropping an empty message is `Degraded`, so each is recorded.
      messages.count(&.content.empty?).times do
        report.record(Capability::Structural.outcome(
          Capability::Structural::Adaptation::DropEmptyMessage),
          "empty message removed to satisfy validation")
      end

      messages = messages.reject(&.content.empty?)
      return messages if messages.empty?

      if messages.first.role == "assistant"
        report.record(Capability::Structural.outcome(
          Capability::Structural::Adaptation::PrependUserPlaceholder),
          "history opens with an assistant turn")
        messages.unshift(Wire::Message.new("user",
          [Wire::TextBlock.new(FIRST_USER_PLACEHOLDER).as(Wire::Block)], synthetic: true))
      end

      merged = [] of Wire::Message
      messages.each do |message|
        previous = merged.last?
        if previous && previous.role == message.role
          report.record(Capability::Structural.outcome(
            Capability::Structural::Adaptation::MergeConsecutiveRoles),
            "consecutive #{message.role} messages merged")
          merged[merged.size - 1] = Wire::Message.new(
            previous.role, previous.content + message.content, previous.synthetic?)
        else
          merged << message
        end
      end

      merged
    end

    private def blocks_for(message : MPSH::Message, index : Int32,
                           report : Capability::Report,
                           plan : Capability::Retention::Plan) : Array(Wire::Block)
      blocks = [] of Wire::Block

      message.content.each do |block|
        case block
        in MPSH::ReasoningBlock
          next unless plan.retain?(index)
          rendered = thinking(block, index, report)
          blocks << rendered if rendered
        in MPSH::ToolCallBlock
          rendered = tool_use(block, index, report)
          blocks << rendered if rendered
        in MPSH::ToolResultBlock
          rendered = tool_result(block, index, report)
          blocks << rendered if rendered
        in MPSH::RefusalBlock
          rendered = refusal(block, index, report)
          blocks << rendered if rendered
        in MPSH::TextBlock, MPSH::ImageBlock, MPSH::AudioBlock, MPSH::DocumentBlock
          rendered = render(block, index, report)
          blocks << rendered if rendered
        end
      end

      blocks
    end

    # Nested content maps straight through, in position, with no placeholder
    # and no synthesized message.
    private def tool_result(block : MPSH::ToolResultBlock, index : Int32,
                            report : Capability::Report) : Wire::Block?
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "tool result with nested content",
        index, MPSH::BlockKind::ToolResult)
      return if outcome.lossy?

      nested = [] of Wire::Block
      block.content.each do |inner|
        rendered = render(inner, index, report, Capability::Resolver::Nesting::InsideToolResult)
        nested << rendered if rendered
      end

      provider_id = calls.provider_id(block.call_id) || block.call_id

      if block.server_executed?
        meta = block.meta_for(profile.metadata_key)
        block_type = meta.try(&.["result_type"]?).try(&.as?(String)) || "web_search_tool_result"
        return Wire::ServerToolResultBlock.new(provider_id, nested, block_type)
      end

      Wire::ToolResultBlock.new(provider_id, nested, block.is_error?)
    end

    private def tool_use(block : MPSH::ToolCallBlock, index : Int32,
                         report : Capability::Report) : Wire::Block?
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "tool call as a tool_use block", index, MPSH::BlockKind::ToolCall)
      return if outcome.lossy?

      provider_id = calls.provider_id(block.call_id) || block.call_id
      calls.bind(block.call_id, provider_id)

      # A provider-run call is its own block type here; as `tool_use` it would
      # lose the flag and invite dispatch.
      if block.server_executed?
        return Wire::ServerToolUseBlock.new(provider_id, block.name, block.arguments.to_json)
      end

      Wire::ToolUseBlock.new(provider_id, block.name, block.arguments.to_json)
    end

    private def thinking(block : MPSH::ReasoningBlock, index : Int32,
                         report : Capability::Report) : Wire::Block?
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "reasoning as a thinking block", index, MPSH::BlockKind::Reasoning)
      return if outcome.lossy?

      meta = block.meta_for(profile.metadata_key)
      Wire::ThinkingBlock.new(block.text,
        signature: meta.try(&.["signature"]?).try(&.as?(String)),
        redacted_data: meta.try(&.["redacted_data"]?).try(&.as?(String)))
    end

    # No refusal channel, so the reason travels as text. A refusal with no
    # reason has nothing to carry, which the resolver reports as `Degraded`.
    private def refusal(block : MPSH::RefusalBlock, index : Int32,
                        report : Capability::Report) : Wire::Block?
      outcome = Capability::Resolver.outcome(block, profile)
      report.record(outcome, "refusal carried as text", index, MPSH::BlockKind::Refusal)
      block.reason.try { |reason| Wire::TextBlock.new(reason) }
    end

    private def render(block : MPSH::Block, index : Int32, report : Capability::Report,
                       nesting = Capability::Resolver::Nesting::TopLevel) : Wire::Block?
      case block
      in MPSH::TextBlock
        Wire::TextBlock.new(block.text)
      in MPSH::ImageBlock, MPSH::AudioBlock, MPSH::DocumentBlock
        binary(block, index, report, nesting)
      in MPSH::ToolCallBlock, MPSH::ToolResultBlock, MPSH::ReasoningBlock, MPSH::RefusalBlock
        nil
      end
    end

    # No audio is accepted, so a voice note becomes its transcript or is
    # refused.
    private def binary(block : MPSH::BinaryBlock, index : Int32,
                       report : Capability::Report,
                       nesting : Capability::Resolver::Nesting) : Wire::Block?
      outcome = Capability::Resolver.outcome(block, profile, nesting)
      report.record(outcome, "#{block.kind.to_s.downcase} #{block.media_type}", index, block.kind)

      case outcome
      when MPSH::Outcome::Degraded
        block.text_fallback.try { |text| Wire::TextBlock.new(text) }
      when MPSH::Outcome::Refused
        nil
      else
        payload = materialize(block.payload)
        case block
        when MPSH::ImageBlock
          Wire::ImageBlock.new(payload.media_type, payload.base64)
        when MPSH::DocumentBlock
          Wire::DocumentBlock.new(payload.media_type, payload.base64, block.name)
        end
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
