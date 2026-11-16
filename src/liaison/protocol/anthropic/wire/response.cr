require "json"
require "./request"
require "../capabilities"
require "../../errors"
require "../../fields"
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
        # An explicit JSON `null` reads as absent.
        return unless any.try(&.as_h?)

        new(Fields.int(any, "input_tokens"), Fields.int(any, "output_tokens"))
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
        parsed = Fields.parse_object(body, NAME)

        raw = Fields.array(parsed, "content")
        unless raw
          raise MalformedResponseError.new(NAME, "response has no `content` array")
        end

        new(raw.compact_map { |entry| block(entry).as(Block?) },
          id: Fields.string(parsed, "id"),
          model: Fields.string(parsed, "model"),
          role: Fields.string(parsed, "role") || "assistant",
          stop_reason: Fields.string(parsed, "stop_reason"),
          stop_sequence: Fields.string(parsed, "stop_sequence"),
          usage: Usage.parse(Fields.at(parsed, "usage")))
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
        type = Fields.string(any, "type")
        return unless type

        case type
        when "text"
          Fields.string(any, "text").try { |text| TextBlock.new(text) }
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
            DocumentBlock.new(parts[0], parts[1], Fields.string(any, "title"))
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
        name = Fields.string(any, "name")
        return unless name

        # `input` is a structured object here. It is re-serialized to raw JSON
        # text, and parsed once, on export.
        {Fields.string(any, "id") || "", name, (Fields.at(any, "input") || JSON::Any.new({} of String => JSON::Any)).to_json}
      end

      private def self.binary(any : JSON::Any) : {String, String}?
        source = Fields.object(any, "source")
        return unless source
        # Inline base64 only. A URL source names bytes this reader does not
        # have, and it does not invent a payload.
        return unless Fields.string(source, "type") == "base64"

        media_type = Fields.string(source, "media_type")
        data = Fields.string(source, "data")
        return unless media_type && data

        {media_type, data}
      end

      private def self.tool_result(any : JSON::Any) : Block?
        id = Fields.string(any, "tool_use_id")
        return unless id

        ToolResultBlock.new(id, nested(any), Fields.bool(any, "is_error") || false)
      end

      private def self.server_tool_result(any : JSON::Any, type : String) : Block?
        id = Fields.string(any, "tool_use_id")
        return unless id

        ServerToolResultBlock.new(id, nested(any), type)
      end

      # `content` nests, so this recurses: an image-bearing tool result is
      # native here.
      private def self.nested(any : JSON::Any) : Array(Block)
        body = Fields.at(any, "content")
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
          Fields.string(any, "thinking"),
          signature: Fields.string(any, "signature"),
          redacted_data: Fields.string(any, "data"))
      end
    end
  end
end
