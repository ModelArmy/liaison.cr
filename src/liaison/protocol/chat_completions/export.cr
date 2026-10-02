require "./wire/request"
require "./wire/response"
require "./mapper"
require "../../capability/carrier"
require "../../mpsh/session"
require "../../mpsh/translation"

module Liaison::Protocol::ChatCompletions
  # Wire in, MPSH out, for a request body. Three signals, most reliable first:
  #
  # 1. `call_id` pairing, explicit on the wire. Results are never paired by
  #    adjacency.
  # 2. Position plus the placeholder marker, which tells a compensation
  #    carrier from genuine user input.
  # 3. Message boundaries between adjacent tool results, which the wire cannot
  #    express. A run collapses into one MPSH user message, a declared
  #    adaptation.
  class Exporter
    getter calls : MPSH::CallIdTable

    def initialize(@calls : MPSH::CallIdTable = MPSH::CallIdTable.new(NAME))
    end

    def export(request : Wire::Request) : MPSH::Session
      export(request.messages)
    end

    # Reads a reply body: one assistant turn, so there is no system prompt,
    # carrier or tool-result run to handle. `tool_calls` is unhoisted into
    # blocks by the same code as on the request side.
    def export_reply(body : String) : MPSH::Message
      export_reply(Wire::Response.from_json(body))
    end

    def export_reply(response : Wire::Response) : MPSH::Message
      choice = response.choice
      unless choice
        raise MalformedResponseError.new(NAME, "response has no choices")
      end

      reply = MPSH::Message.new(MPSH::Role::Assistant,
        assistant_blocks(choice.message),
        response.model.try { |model| MPSH::Provenance.new(NAME, model) })

      # Kept namespaced. `length` also sets `Message#ending` to `Truncated`, so
      # a reloaded session knows the turn was cut without knowing this
      # protocol's spelling.
      choice.finish_reason.try do |value|
        reply.put_meta(METADATA_KEY, "finish_reason", value)
        reply.ending = MPSH::Ending::Truncated if value == "length"
      end
      response.id.try { |value| reply.put_meta(METADATA_KEY, "response_id", value) }
      response.usage.try { |usage| reply.put_meta(METADATA_KEY, "usage", usage.to_metadata) }

      reply
    end

    def export(messages : Array(Wire::Message)) : MPSH::Session
      session = MPSH::Session.new
      # Tool results awaiting either a carrier or a boundary.
      run = [] of MPSH::ToolResultBlock

      messages.each do |message|
        case message.role
        when "system"
          session.system_prompt = merge_system(session.system_prompt, text_of(message))
        when "tool"
          run << tool_result(message)
        when "assistant"
          flush_run(session, run)
          assistant(session, message)
        when "user"
          if carrier?(message, run)
            absorb_carrier(message, run)
          else
            flush_run(session, run)
            session << MPSH::Message.new(MPSH::Role::User, parts_to_blocks(message))
          end
        end
      end

      flush_run(session, run)
      session
    end

    # Whether a `user` message after tool results is a compensation carrier
    # rather than genuine input; the signals and their limits are in
    # `Capability::Carrier`. Content that is a bare `String` has no parts to
    # inspect and is never a carrier.
    private def carrier?(message : Wire::Message, run : Array(MPSH::ToolResultBlock)) : Bool
      body = message.content
      parts = body.is_a?(Array(Wire::Part)) ? body : [] of Wire::Part

      Capability::Carrier.carrier?(run, message.synthetic?, parts,
        eligible: body.is_a?(Array(Wire::Part))) { |part| part.is_a?(Wire::TextPart) }
    end

    # Carrier content is returned to the result that referenced it, in order.
    private def absorb_carrier(message : Wire::Message, run : Array(MPSH::ToolResultBlock)) : Nil
      body = message.content
      return unless body.is_a?(Array(Wire::Part))

      Capability::Carrier.absorb(run, body) { |part| part_to_block(part) }
    end

    # A consecutive run of `role: "tool"` messages becomes one user message;
    # separate turns come back joined.
    private def flush_run(session : MPSH::Session, run : Array(MPSH::ToolResultBlock)) : Nil
      return if run.empty?
      blocks = run.map(&.as(MPSH::Block))
      session << MPSH::Message.new(MPSH::Role::User, blocks)
      run.clear
    end

    private def tool_result(message : Wire::Message) : MPSH::ToolResultBlock
      provider_id = message.tool_call_id || ""
      MPSH::ToolResultBlock.new(calls.mpsh_id(provider_id), split_placeholders(text_of(message)))
    end

    private def split_placeholders(body : String) : Array(MPSH::Block)
      Capability::Carrier.split(body)
    end

    private def assistant(session : MPSH::Session, message : Wire::Message) : Nil
      session << MPSH::Message.new(MPSH::Role::Assistant, assistant_blocks(message))
    end

    # Reads an assistant message, for both a reply and a request's history.
    private def assistant_blocks(message : Wire::Message) : Array(MPSH::Block)
      blocks = [] of MPSH::Block

      # Reasoning first, matching where providers place it in a turn.
      if reasoning = message.reasoning_content
        blocks << MPSH::ReasoningBlock.new(reasoning)
      end

      blocks.concat(parts_to_blocks(message))

      if refusal = message.refusal
        blocks << MPSH::RefusalBlock.new(refusal)
      end

      # Unhoisting: the message-level field becomes blocks.
      message.tool_calls.try &.each do |call|
        blocks << MPSH::ToolCallBlock.new(
          calls.mpsh_id(call.id), call.name, parse_arguments(call.arguments))
      end

      blocks
    end

    private def parts_to_blocks(message : Wire::Message) : Array(MPSH::Block)
      case body = message.content
      in String
        body.empty? ? [] of MPSH::Block : [MPSH::TextBlock.new(body).as(MPSH::Block)]
      in Array(Wire::Part)
        # Widened per element: `compact_map` would otherwise infer a union
        # narrower than `MPSH::Block`.
        body.compact_map { |part| part_to_block(part).as(MPSH::Block?) }
      in Nil
        [] of MPSH::Block
      end
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

    # Splits a `data:` URI back into media type and base64.
    private def split_data_uri(url : String) : {String, String}
      unless url.starts_with?("data:") && url.includes?(";base64,")
        raise Capability::RefusedError.new(NAME, "image URL is not an inline data URI: #{url[0, 32]}")
      end

      head, _, body = url[5..].partition(";base64,")
      {head, body}
    end

    private def parse_arguments(json : String) : MPSH::Object
      parsed = JSON.parse(json)
      raw = parsed.as_h?
      return MPSH::Object.new unless raw

      raw.each_with_object(MPSH::Object.new) do |(key, value), acc|
        acc[key] = to_value(value)
      end
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

    private def merge_system(existing : String?, addition : String) : String
      return addition unless existing
      "#{existing}\n\n#{addition}"
    end

    private def text_of(message : Wire::Message) : String
      case body = message.content
      in String            then body
      in Array(Wire::Part) then body.compact_map { |part| part.as?(Wire::TextPart).try &.text }.join("\n")
      in Nil               then ""
      end
    end

    private def byte_size(base64 : String) : Int64
      (base64.size * 3 // 4).to_i64
    end
  end
end
