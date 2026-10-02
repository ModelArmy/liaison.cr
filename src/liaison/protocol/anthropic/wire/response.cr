require "json"
require "./request"
require "../capabilities"
require "../../errors"
require "../../../mpsh/meta"

module Liaison::Protocol::Anthropic
  # The response half of the wire form. The reply is the top-level object,
  # with `content[]` at its root.
  #
  # `server_tool_use` and its result arrive already executed, and are kept
  # distinct from `tool_use`: read as an ordinary call, one would be handed to
  # the caller to dispatch.
  module Wire
    struct Usage
      getter input_tokens : Int32?
      getter output_tokens : Int32?

      def initialize(@input_tokens : Int32? = nil, @output_tokens : Int32? = nil)
      end

      def self.parse(any : JSON::Any?) : Usage?
        # `as_h?` rather than a nil check, so an explicit JSON `null` reads as
        # absent instead of being indexed as a hash.
        fields = any.try(&.as_h?)
        return unless fields

        new(fields["input_tokens"]?.try(&.as_i?), fields["output_tokens"]?.try(&.as_i?))
      end

      def to_metadata : MPSH::Object
        object = MPSH::Object.new
        @input_tokens.try { |value| object["input_tokens"] = value.to_i64 }
        @output_tokens.try { |value| object["output_tokens"] = value.to_i64 }
        object
      end
    end

    struct Response
      getter id : String?
      getter model : String?
      getter role : String
      getter content : Array(Block)
      getter stop_reason : String?
      getter stop_sequence : String?
      getter usage : Usage?

      def initialize(@content : Array(Block), @id : String? = nil, @model : String? = nil,
                     @role : String = "assistant", @stop_reason : String? = nil,
                     @stop_sequence : String? = nil, @usage : Usage? = nil)
      end

      def self.from_json(body : String) : Response
        parsed = begin
          JSON.parse(body)
        rescue error : JSON::ParseException
          raise MalformedResponseError.new(NAME, "response body is not JSON: #{error.message}")
        end

        raw = parsed["content"]?.try(&.as_a?)
        unless raw
          raise MalformedResponseError.new(NAME, "response has no `content` array")
        end

        new(raw.compact_map { |entry| block(entry).as(Block?) },
          id: parsed["id"]?.try(&.as_s?),
          model: parsed["model"]?.try(&.as_s?),
          role: parsed["role"]?.try(&.as_s?) || "assistant",
          stop_reason: parsed["stop_reason"]?.try(&.as_s?),
          stop_sequence: parsed["stop_sequence"]?.try(&.as_s?),
          usage: Usage.parse(parsed["usage"]?))
      end

      # One content block, from an object someone else assembled. The stream
      # assembler rebuilds each block and reads it here, so streamed and
      # buffered blocks are read by the same rules.
      def self.from_content_block(any : JSON::Any) : Block?
        block(any)
      end

      # Reads every block type the protocol defines, not only those a model is
      # expected to emit.
      private def self.block(any : JSON::Any) : Block?
        type = any["type"]?.try(&.as_s?)
        return unless type

        case type
        when "text"
          any["text"]?.try(&.as_s?).try { |text| TextBlock.new(text) }
        when "thinking", "redacted_thinking"
          thinking(any)
        when "tool_use"
          tool_use(any).try { |parts| ToolUseBlock.new(*parts) }
        when "server_tool_use"
          # A provider-run call: its own block type.
          tool_use(any).try { |parts| ServerToolUseBlock.new(*parts) }
        when "image"
          binary(any).try { |parts| ImageBlock.new(*parts) }
        when "document"
          binary(any).try do |parts|
            DocumentBlock.new(parts[0], parts[1], any["title"]?.try(&.as_s?))
          end
        when "tool_result"
          tool_result(any)
        else
          # Server-tool results are matched by the `_tool_result` suffix, so a
          # new provider-run tool reads as provider-run without a code change.
          type.ends_with?("_tool_result") ? server_tool_result(any, type) : nil
        end
      end

      private def self.tool_use(any : JSON::Any) : {String, String, String}?
        name = any["name"]?.try(&.as_s?)
        return unless name

        # `input` is a structured object here. It is re-serialized to raw JSON
        # text, and parsed once, on export.
        {any["id"]?.try(&.as_s?) || "", name, (any["input"]? || JSON::Any.new({} of String => JSON::Any)).to_json}
      end

      private def self.binary(any : JSON::Any) : {String, String}?
        source = any["source"]?
        return unless source
        # Inline base64 only. A URL source names bytes this reader does not
        # have, and it does not invent a payload.
        return unless source["type"]?.try(&.as_s?) == "base64"

        media_type = source["media_type"]?.try(&.as_s?)
        data = source["data"]?.try(&.as_s?)
        return unless media_type && data

        {media_type, data}
      end

      private def self.tool_result(any : JSON::Any) : Block?
        id = any["tool_use_id"]?.try(&.as_s?)
        return unless id

        ToolResultBlock.new(id, nested(any), any["is_error"]?.try(&.as_bool?) || false)
      end

      private def self.server_tool_result(any : JSON::Any, type : String) : Block?
        id = any["tool_use_id"]?.try(&.as_s?)
        return unless id

        ServerToolResultBlock.new(id, nested(any), type)
      end

      # `content` nests, so this recurses: an image-bearing tool result is
      # native here.
      private def self.nested(any : JSON::Any) : Array(Block)
        body = any["content"]?
        return [] of Block unless body

        if text = body.as_s?
          [TextBlock.new(text).as(Block)]
        elsif entries = body.as_a?
          entries.compact_map { |entry| block(entry).as(Block?) }
        else
          [] of Block
        end
      end

      # Keeps the signature, and keeps `redacted_thinking`, which has no text,
      # as a block, so reasoning that occurred is never dropped.
      private def self.thinking(any : JSON::Any) : Block
        ThinkingBlock.new(
          any["thinking"]?.try(&.as_s?),
          signature: any["signature"]?.try(&.as_s?),
          redacted_data: any["data"]?.try(&.as_s?))
      end
    end
  end
end
