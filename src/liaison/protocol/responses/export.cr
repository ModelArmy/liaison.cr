require "./wire/request"
require "./wire/response"
require "./mapper"
require "../../capability/carrier"
require "../../mpsh/session"
require "../../mpsh/translation"

module Liaison::Protocol::Responses
  # Wire in, MPSH out, for a request body. Items map almost one-to-one onto
  # blocks. A tool output is a string, so compensation carriers are recognised
  # and absorbed, and adjacent outputs collapse into one user message.
  class Exporter
    getter calls : MPSH::CallIdTable

    def initialize(@calls : MPSH::CallIdTable = MPSH::CallIdTable.new(NAME))
    end

    def export(request : Wire::Request) : MPSH::Session
      session = MPSH::Session.new(request.instructions)
      run = [] of MPSH::ToolResultBlock
      # Assistant items arrive separately (reasoning, calls, a message) and are
      # gathered into one MPSH message.
      assistant = [] of MPSH::Block

      request.input.each do |item|
        case item
        when Wire::ReasoningItem
          flush_run(session, run)
          assistant << reasoning(item)
        when Wire::FunctionCallItem
          flush_run(session, run)
          assistant << MPSH::ToolCallBlock.new(
            calls.mpsh_id(item.call_id), item.name, parse_arguments(item.arguments))
        when Wire::FunctionCallOutputItem
          flush_assistant(session, assistant)
          run << MPSH::ToolResultBlock.new(
            calls.mpsh_id(item.call_id), split_placeholders(item.output))
        when Wire::RefusalItem
          flush_run(session, run)
          assistant << MPSH::RefusalBlock.new(item.reason)
        when Wire::MessageItem
          message_item(session, item, run, assistant)
        end
      end

      flush_assistant(session, assistant)
      flush_run(session, run)
      session
    end

    # Reads a reply body. Every item in `output[]` is an assistant item, so
    # they are gathered in one pass.
    def export_reply(body : String) : MPSH::Message
      export_reply(Wire::Response.from_json(body))
    end

    def export_reply(response : Wire::Response) : MPSH::Message
      blocks = [] of MPSH::Block

      response.output.each do |item|
        case item
        when Wire::ReasoningItem
          blocks << reasoning(item)
        when Wire::FunctionCallItem
          blocks << MPSH::ToolCallBlock.new(
            calls.mpsh_id(item.call_id), item.name, parse_arguments(item.arguments))
        when Wire::RefusalItem
          blocks << MPSH::RefusalBlock.new(item.reason)
        when Wire::MessageItem
          blocks.concat(parts_to_blocks(item.content))
        when Wire::FunctionCallOutputItem
          # A tool output in a reply is ignored: a server echoing input back
          # is odd, not fatal.
          nil
        end
      end

      reply = MPSH::Message.new(MPSH::Role::Assistant, blocks,
        response.model.try { |model| MPSH::Provenance.new(NAME, model) })

      # `incomplete` sets `Message#ending` to `Truncated`. It covers both an
      # output cap and a cut stream; for a cut stream, `Client` then sets
      # `Interrupted` or `Stopped`.
      response.status.try do |value|
        reply.put_meta(METADATA_KEY, "status", value)
        reply.ending = MPSH::Ending::Truncated if value == "incomplete"
      end
      response.id.try { |value| reply.put_meta(METADATA_KEY, "response_id", value) }
      response.usage.try { |usage| reply.put_meta(METADATA_KEY, "usage", usage.to_metadata) }

      reply
    end

    private def message_item(session : MPSH::Session, item : Wire::MessageItem,
                             run : Array(MPSH::ToolResultBlock),
                             assistant : Array(MPSH::Block)) : Nil
      if item.role == "assistant"
        flush_run(session, run)
        assistant.concat(parts_to_blocks(item.content))
        return
      end

      if carrier?(item, run)
        absorb_carrier(item, run)
        return
      end

      flush_assistant(session, assistant)
      flush_run(session, run)
      session << MPSH::Message.new(MPSH::Role::User, parts_to_blocks(item.content))
    end

    # Whether a user message item after tool outputs is a carrier; see
    # `Capability::Carrier`. Item content is always parts, so there is no
    # local precondition.
    private def carrier?(item : Wire::MessageItem, run : Array(MPSH::ToolResultBlock)) : Bool
      Capability::Carrier.carrier?(run, item.synthetic?, item.content) do |part|
        part.is_a?(Wire::TextPart)
      end
    end

    private def absorb_carrier(item : Wire::MessageItem,
                               run : Array(MPSH::ToolResultBlock)) : Nil
      Capability::Carrier.absorb(run, item.content) { |part| part_to_block(part) }
    end

    private def split_placeholders(body : String) : Array(MPSH::Block)
      Capability::Carrier.split(body)
    end

    private def flush_assistant(session : MPSH::Session,
                                assistant : Array(MPSH::Block)) : Nil
      return if assistant.empty?
      session << MPSH::Message.new(MPSH::Role::Assistant, assistant.dup)
      assistant.clear
    end

    # Adjacent tool outputs become one user message
    # (`CollapseAdjacentToolResults`): pairing survives through `call_id`,
    # only the message boundary is lost.
    private def flush_run(session : MPSH::Session,
                          run : Array(MPSH::ToolResultBlock)) : Nil
      return if run.empty?
      session << MPSH::Message.new(MPSH::Role::User, run.map(&.as(MPSH::Block)))
      run.clear
    end

    # Keeps the opaque payload a text field could not.
    private def reasoning(item : Wire::ReasoningItem) : MPSH::ReasoningBlock
      text = item.summary.empty? ? nil : item.summary.join("\n")
      block = MPSH::ReasoningBlock.new(text, redacted: text.nil?)

      if value = item.encrypted_content
        block.put_meta(METADATA_KEY, "encrypted_content", value)
      end
      if value = item.id
        block.put_meta(METADATA_KEY, "item_id", value)
      end

      block
    end

    private def parts_to_blocks(parts : Array(Wire::Part)) : Array(MPSH::Block)
      parts.compact_map { |part| part_to_block(part).as(MPSH::Block?) }
    end

    private def part_to_block(part : Wire::Part) : MPSH::Block?
      case part
      when Wire::TextPart
        MPSH::TextBlock.new(part.text)
      when Wire::ImagePart
        media_type, base64 = split_data_uri(part.url)
        MPSH::ImageBlock.new(MPSH::InlinePayload.new(base64, media_type, byte_size(base64)))
      when Wire::AudioPart
        MPSH::AudioBlock.new(
          MPSH::InlinePayload.new(part.base64, "audio/#{part.format}", byte_size(part.base64)))
      when Wire::FilePart
        MPSH::DocumentBlock.new(
          MPSH::InlinePayload.new(part.base64, "application/pdf", byte_size(part.base64)),
          part.name)
      end
    end

    private def split_data_uri(url : String) : {String, String}
      unless url.starts_with?("data:") && url.includes?(";base64,")
        raise Capability::RefusedError.new(NAME, "image URL is not an inline data URI: #{url[0, 32]}")
      end

      head, _, body = url[5..].partition(";base64,")
      {head, body}
    end

    private def parse_arguments(json : String) : MPSH::Object
      raw = JSON.parse(json).as_h?
      return MPSH::Object.new unless raw
      raw.each_with_object(MPSH::Object.new) { |(key, value), acc| acc[key] = to_value(value) }
    rescue JSON::ParseException
      MPSH::Object.new
    end

    private def to_value(any : JSON::Any) : MPSH::Value
      case raw = any.raw
      when Nil, Bool, Int64, Float64, String
        raw
      when Array
        raw.map { |item| to_value(item).as(MPSH::Value) }
      when Hash
        raw.each_with_object(MPSH::Object.new) { |(key, item), acc| acc[key] = to_value(item) }
      end
    end

    private def byte_size(base64 : String) : Int64
      (base64.size * 3 // 4).to_i64
    end
  end
end
