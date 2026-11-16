require "json"
require "./request"
require "../capabilities"
require "../../errors"
require "../../fields"
require "../../../mpsh/meta"

module Liaison::Protocol::ChatCompletions
  # The response half of the wire form, parse-only. `choices` holds
  # alternative answers (`n`); this shard never sets `n`, so it reads the
  # first.
  module Wire
    struct Usage
      getter prompt_tokens : Int32?
      getter completion_tokens : Int32?
      getter total_tokens : Int32?

      def initialize(@prompt_tokens : Int32? = nil, @completion_tokens : Int32? = nil,
                     @total_tokens : Int32? = nil)
      end

      def self.parse(any : JSON::Any?) : Usage?
        # An explicit JSON `null`, which a streamed chunk sends until the last,
        # reads as absent.
        return unless any.try(&.as_h?)

        new(Fields.int(any, "prompt_tokens"),
          Fields.int(any, "completion_tokens"),
          Fields.int(any, "total_tokens"))
      end

      def to_metadata : MPSH::Object
        object = MPSH::Object.new
        @prompt_tokens.try { |value| object["prompt_tokens"] = value.to_i64 }
        @completion_tokens.try { |value| object["completion_tokens"] = value.to_i64 }
        @total_tokens.try { |value| object["total_tokens"] = value.to_i64 }
        object
      end
    end

    struct Choice
      getter index : Int32
      getter message : Message
      getter finish_reason : String?

      def initialize(@index : Int32, @message : Message, @finish_reason : String? = nil)
      end
    end

    struct Response
      getter id : String?
      getter model : String?
      getter choices : Array(Choice)
      getter usage : Usage?

      def initialize(@choices : Array(Choice), @id : String? = nil,
                     @model : String? = nil, @usage : Usage? = nil)
      end

      # The one answer requested; see the note above.
      def choice : Choice?
        @choices.first?
      end

      def self.from_json(body : String) : Response
        parsed = Fields.parse_object(body, NAME)

        raw = Fields.array(parsed, "choices")
        unless raw
          raise MalformedResponseError.new(NAME, "response has no `choices` array")
        end

        choices = raw.map_with_index { |entry, index| choice(entry, index) }

        new(choices,
          id: Fields.string(parsed, "id"),
          model: Fields.string(parsed, "model"),
          usage: Usage.parse(Fields.at(parsed, "usage")))
      end

      # One assistant message, from an object someone else assembled. The
      # stream assembler rebuilds the message and reads it here, so both
      # reasoning-field spellings are reconciled in one place.
      def self.from_message(any : JSON::Any) : Message
        message(any)
      end

      private def self.choice(any : JSON::Any, position : Int32) : Choice
        body = Fields.object(any, "message")
        unless body
          raise MalformedResponseError.new(NAME, "choice #{position} has no `message`")
        end

        Choice.new(Fields.int(any, "index") || position,
          message(body),
          Fields.string(any, "finish_reason"))
      end

      # Reuses the request-side `Message`, which has every field a reply
      # carries.
      private def self.message(any : JSON::Any) : Message
        Message.new(
          role: Fields.string(any, "role") || "assistant",
          content: Fields.string(any, "content"),
          tool_calls: tool_calls(Fields.at(any, "tool_calls")),
          refusal: Fields.string(any, "refusal"),
          # Not in OpenAI's specification, and spelled two ways: vLLM and
          # DeepSeek send `reasoning_content`, Ollama sends `reasoning`. Both
          # are read; insisting on one would silently drop the other's trace.
          reasoning_content: Fields.string(any, "reasoning_content") ||
                             Fields.string(any, "reasoning"))
      end

      private def self.tool_calls(any : JSON::Any?) : Array(ToolCall)?
        entries = any.try(&.as_a?)
        return if entries.nil? || entries.empty?

        entries.compact_map do |entry|
          function = Fields.object(entry, "function")
          next unless function

          name = Fields.string(function, "name")
          next unless name

          ToolCall.new(
            Fields.string(entry, "id") || "",
            name,
            # A JSON string on this protocol; kept as text and parsed at
            # export. Any other value is kept as its JSON text, so export
            # judges it rather than this reading it as empty.
            Fields.at(function, "arguments").try { |value| value.as_s? || value.to_json } || "{}")
        end
      end
    end
  end
end
