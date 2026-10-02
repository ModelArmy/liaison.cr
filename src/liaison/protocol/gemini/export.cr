require "./wire/request"
require "./wire/response"
require "./mapper"
require "../../capability/carrier"
require "../../mpsh/session"
require "../../mpsh/translation"

module Liaison::Protocol::Gemini
  # Wire in, MPSH out, for a request body. A `functionResponse` names only
  # the function it answers, so the nth response to a name answers the nth
  # call to it, and `name#ordinal` is minted into an MPSH `call_id` through
  # the `CallIdTable`.
  #
  # This relies on responses arriving in call order; a reordered or missing
  # response would mispair, undetectably.
  class Exporter
    getter calls : MPSH::CallIdTable

    def initialize(@calls : MPSH::CallIdTable = MPSH::CallIdTable.new(NAME))
    end

    def export(request : Wire::Request) : MPSH::Session
      session = MPSH::Session.new(request.system_instruction)
      call_ordinals = Hash(String, Int32).new(0)
      response_ordinals = Hash(String, Int32).new(0)
      pending_results = [] of MPSH::ToolResultBlock

      request.contents.each do |content|
        if carrier?(content, pending_results)
          absorb_carrier(content, pending_results)
          next
        end

        pending_results.clear
        role = content.role == "model" ? MPSH::Role::Assistant : MPSH::Role::User
        blocks = [] of MPSH::Block

        content.parts.each do |part|
          block = to_block(part, call_ordinals, response_ordinals)
          next unless block
          pending_results << block if block.is_a?(MPSH::ToolResultBlock)
          blocks << block
        end

        session << MPSH::Message.new(role, blocks) unless blocks.empty?
      end

      session
    end

    # Reads a reply body; `candidates[]` holds alternatives, so index 0 is the
    # reply.
    #
    # A reply's calls are keyed in their own space rather than the session's
    # ordinals, which they have not been counted into; reusing `name#0` would
    # collide with a call already bound. Only the name must survive, and the
    # next `map` rebinds each call to its session ordinal.
    def export_reply(body : String) : MPSH::Message
      export_reply(Wire::Response.from_json(body))
    end

    def export_reply(response : Wire::Response) : MPSH::Message
      candidate = response.candidate
      unless candidate
        raise MalformedResponseError.new(NAME, "response has no candidates")
      end

      blocks = [] of MPSH::Block
      ordinals = Hash(String, Int32).new(0)

      candidate.content.parts.each do |part|
        block = reply_block(part, ordinals)
        blocks << block if block
      end

      reply = MPSH::Message.new(MPSH::Role::Assistant, blocks,
        response.model_version.try { |model| MPSH::Provenance.new(NAME, model) })

      # `MAX_TOKENS` means the output cap cut the turn short: normalised onto
      # `Message#ending`, and kept verbatim.
      candidate.finish_reason.try do |value|
        reply.put_meta(METADATA_KEY, "finishReason", value)
        reply.ending = MPSH::Ending::Truncated if value == "MAX_TOKENS"
      end
      response.usage.try { |usage| reply.put_meta(METADATA_KEY, "usage", usage.to_metadata) }

      reply
    end

    # A reply holds no tool results, only calls, keyed as above.
    private def reply_block(part : Wire::Part, ordinals : Hash(String, Int32)) : MPSH::Block?
      case part
      when Wire::FunctionCallPart
        ordinal = ordinals[part.name]
        ordinals[part.name] = ordinal + 1
        tool_call(calls.mpsh_id("#{part.name}#reply:#{ordinal}"), part)
      when Wire::TextPart
        MPSH::TextBlock.new(part.text)
      when Wire::InlineDataPart
        binary(part)
      when Wire::ThoughtPart
        thought(part)
      end
    end

    private def to_block(part : Wire::Part,
                         call_ordinals : Hash(String, Int32),
                         response_ordinals : Hash(String, Int32)) : MPSH::Block?
      case part
      when Wire::TextPart
        MPSH::TextBlock.new(part.text)
      when Wire::InlineDataPart
        binary(part)
      when Wire::FunctionCallPart
        ordinal = call_ordinals[part.name]
        call_ordinals[part.name] = ordinal + 1
        tool_call(calls.mpsh_id(calls.positional_key(part.name, ordinal)), part)
      when Wire::FunctionResponsePart
        ordinal = response_ordinals[part.name]
        response_ordinals[part.name] = ordinal + 1
        MPSH::ToolResultBlock.new(
          calls.mpsh_id(calls.positional_key(part.name, ordinal)),
          split_placeholders(response_text(part.response)))
      when Wire::ThoughtPart
        thought(part)
      end
    end

    # Keeps the call's `thoughtSignature` in `provider_metadata`, where a
    # thought's is kept. A call from another protocol has nothing there, and
    # `Resolver` treats both alike.
    private def tool_call(mpsh_id : String, part : Wire::FunctionCallPart) : MPSH::ToolCallBlock
      block = MPSH::ToolCallBlock.new(mpsh_id, part.name, parse_object(part.args))
      if value = part.thought_signature
        block.put_meta(METADATA_KEY, "thought_signature", value)
      end
      block
    end

    # The response payload is an object on this protocol. `{"output": ...}`
    # yields its text; anything else is kept whole as text.
    private def response_text(json : String) : String
      parsed = JSON.parse(json)
      parsed["output"]?.try(&.as_s?) || json
    rescue JSON::ParseException
      json
    end

    private def thought(part : Wire::ThoughtPart) : MPSH::ReasoningBlock
      text = part.text.try { |value| value.empty? ? nil : value }
      block = MPSH::ReasoningBlock.new(text, redacted: text.nil?)
      if value = part.signature
        block.put_meta(METADATA_KEY, "thought_signature", value)
      end
      block
    end

    private def binary(part : Wire::InlineDataPart) : MPSH::Block
      payload = MPSH::InlinePayload.new(part.base64, part.mime_type, byte_size(part.base64))

      case part.mime_type.partition('/')[0]
      when "image" then MPSH::ImageBlock.new(payload)
      when "audio" then MPSH::AudioBlock.new(payload)
      else              MPSH::DocumentBlock.new(payload, "document")
      end
    end

    # A carrier is a `user` content, never a `model` one. Passed as
    # `eligible`, so it is checked after `synthetic?`.
    private def carrier?(content : Wire::Content,
                         pending : Array(MPSH::ToolResultBlock)) : Bool
      Capability::Carrier.carrier?(pending, content.synthetic?, content.parts,
        eligible: content.role == "user") { |part| part.is_a?(Wire::TextPart) }
    end

    # Fresh ordinal tables: a carrier holds lifted media, never a call or
    # response.
    private def absorb_carrier(content : Wire::Content,
                               pending : Array(MPSH::ToolResultBlock)) : Nil
      Capability::Carrier.absorb(pending, content.parts) do |part|
        to_block(part, Hash(String, Int32).new(0), Hash(String, Int32).new(0))
      end
    end

    private def split_placeholders(body : String) : Array(MPSH::Block)
      Capability::Carrier.split(body)
    end

    private def parse_object(json : String) : MPSH::Object
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
