require "./wire/request"
require "./wire/response"
require "./mapper"
require "../arguments"
require "../../mpsh/session"
require "../../mpsh/translation"

module Liaison::Protocol::Anthropic
  # Wire in, MPSH out. Tool calls, results and thinking are already content
  # blocks, so little is restructured. Merged messages cannot be unmerged,
  # and the first-user placeholder is recognised only by its exact text.
  class Exporter
    getter calls : MPSH::CallIdTable

    def initialize(@calls : MPSH::CallIdTable = MPSH::CallIdTable.new(NAME))
    end

    def export(request : Wire::Request) : MPSH::Session
      session = MPSH::Session.new(request.system)

      request.messages.each do |message|
        next if placeholder?(message)

        role = message.role == "assistant" ? MPSH::Role::Assistant : MPSH::Role::User
        session << MPSH::Message.new(role, blocks_for(message))
      end

      session
    end

    # Reads a reply body. `server_tool_use` becomes a call marked
    # `server_executed`, so a caller's dispatch loop skips it.
    def export_reply(body : String) : MPSH::Message
      export_reply(Wire::Response.from_json(body))
    end

    def export_reply(response : Wire::Response) : MPSH::Message
      blocks = response.content.compact_map { |block| to_block(block).as(MPSH::Block?) }

      reply = MPSH::Message.new(MPSH::Role::Assistant, blocks,
        response.model.try { |model| MPSH::Provenance.new(NAME, model) })

      # `max_tokens` means the output cap cut the turn short: normalised onto
      # `Message#ending`, and kept verbatim.
      response.stop_reason.try do |value|
        reply.put_meta(METADATA_KEY, "stop_reason", value)
        reply.ending = MPSH::Ending::Truncated if value == "max_tokens"
      end
      response.stop_sequence.try { |value| reply.put_meta(METADATA_KEY, "stop_sequence", value) }
      response.id.try { |value| reply.put_meta(METADATA_KEY, "response_id", value) }
      response.usage.try { |usage| reply.put_meta(METADATA_KEY, "usage", usage.to_metadata) }

      reply
    end

    # The first-user placeholder, recognised by its exact text. A foreign
    # session with other wording goes undetected, and a genuine opening message
    # with this text is misread.
    private def placeholder?(message : Wire::Message) : Bool
      return true if message.synthetic?
      return false unless message.role == "user" && message.content.size == 1

      first = message.content.first
      first.is_a?(Wire::TextBlock) && first.text == FIRST_USER_PLACEHOLDER
    end

    private def blocks_for(message : Wire::Message) : Array(MPSH::Block)
      message.content.compact_map { |block| to_block(block).as(MPSH::Block?) }
    end

    private def to_block(block : Wire::Block) : MPSH::Block?
      case block
      when Wire::TextBlock
        MPSH::TextBlock.new(block.text)
      when Wire::ImageBlock
        MPSH::ImageBlock.new(
          MPSH::InlinePayload.new(block.base64, block.media_type, byte_size(block.base64)))
      when Wire::DocumentBlock
        MPSH::DocumentBlock.new(
          MPSH::InlinePayload.new(block.base64, block.media_type, byte_size(block.base64)),
          block.title || "document")
      when Wire::ToolUseBlock
        MPSH::ToolCallBlock.new(
          calls.mpsh_id(block.id), block.name, Arguments.read(block.input, NAME, block.name))
      when Wire::ToolResultBlock
        # Nested content returns as it was, in position.
        MPSH::ToolResultBlock.new(
          calls.mpsh_id(block.tool_use_id),
          block.content.compact_map { |nested| to_block(nested).as(MPSH::Block?) },
          is_error: block.is_error?)
      when Wire::ServerToolUseBlock
        MPSH::ToolCallBlock.new(calls.mpsh_id(block.id), block.name,
          Arguments.read(block.input, NAME, block.name), server_executed: true)
      when Wire::ServerToolResultBlock
        server_result(block)
      when Wire::ThinkingBlock
        thinking(block)
      end
    end

    # The result type is tool-specific, so it is kept under the vendor
    # namespace for the next mapping.
    private def server_result(block : Wire::ServerToolResultBlock) : MPSH::ToolResultBlock
      exported = MPSH::ToolResultBlock.new(
        calls.mpsh_id(block.tool_use_id),
        block.content.compact_map { |nested| to_block(nested).as(MPSH::Block?) },
        server_executed: true)
      exported.put_meta(METADATA_KEY, "result_type", block.block_type)
      exported
    end

    # Keeps the signature in namespaced metadata for replay, and keeps
    # `redacted_thinking`, which has no text, as a redacted block.
    private def thinking(block : Wire::ThinkingBlock) : MPSH::ReasoningBlock
      redacted = block.redacted_data != nil
      text = redacted ? nil : block.thinking
      exported = MPSH::ReasoningBlock.new(text, redacted: redacted || text.nil?)

      if value = block.signature
        exported.put_meta(METADATA_KEY, "signature", value)
      end
      if value = block.redacted_data
        exported.put_meta(METADATA_KEY, "redacted_data", value)
      end

      exported
    end

    private def byte_size(base64 : String) : Int64
      (base64.size * 3 // 4).to_i64
    end
  end
end
