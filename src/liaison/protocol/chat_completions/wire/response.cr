require "json"
require "./request"
require "../capabilities"
require "../../errors"
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
        # `as_h?` rather than a nil check: a streamed chunk carries
        # `"usage": null` until the last one, and an explicit JSON `null` must
        # read as absent instead of being indexed as a hash.
        fields = any.try(&.as_h?)
        return unless fields

        new(fields["prompt_tokens"]?.try(&.as_i?),
          fields["completion_tokens"]?.try(&.as_i?),
          fields["total_tokens"]?.try(&.as_i?))
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
        parsed = begin
          JSON.parse(body)
        rescue error : JSON::ParseException
          raise MalformedResponseError.new(NAME, "response body is not JSON: #{error.message}")
        end

        raw = parsed["choices"]?.try(&.as_a?)
        unless raw
          raise MalformedResponseError.new(NAME, "response has no `choices` array")
        end

        choices = raw.map_with_index { |entry, index| choice(entry, index) }

        new(choices,
          id: parsed["id"]?.try(&.as_s?),
          model: parsed["model"]?.try(&.as_s?),
          usage: Usage.parse(parsed["usage"]?))
      end

      # One assistant message, from an object someone else assembled. The
      # stream assembler rebuilds the message and reads it here, so both
      # reasoning-field spellings are reconciled in one place.
      def self.from_message(any : JSON::Any) : Message
        message(any)
      end

      private def self.choice(any : JSON::Any, position : Int32) : Choice
        body = any["message"]?
        unless body
          raise MalformedResponseError.new(NAME, "choice #{position} has no `message`")
        end

        Choice.new(any["index"]?.try(&.as_i?) || position,
          message(body),
          any["finish_reason"]?.try(&.as_s?))
      end

      # Reuses the request-side `Message`, which has every field a reply
      # carries.
      private def self.message(any : JSON::Any) : Message
        Message.new(
          role: any["role"]?.try(&.as_s?) || "assistant",
          content: any["content"]?.try(&.as_s?),
          tool_calls: tool_calls(any["tool_calls"]?),
          refusal: any["refusal"]?.try(&.as_s?),
          # Not in OpenAI's specification, and spelled two ways: vLLM and
          # DeepSeek send `reasoning_content`, Ollama sends `reasoning`. Both
          # are read; insisting on one would silently drop the other's trace.
          reasoning_content: any["reasoning_content"]?.try(&.as_s?) ||
                             any["reasoning"]?.try(&.as_s?))
      end

      private def self.tool_calls(any : JSON::Any?) : Array(ToolCall)?
        entries = any.try(&.as_a?)
        return if entries.nil? || entries.empty?

        entries.compact_map do |entry|
          function = entry["function"]?
          next unless function

          name = function["name"]?.try(&.as_s?)
          next unless name

          ToolCall.new(
            entry["id"]?.try(&.as_s?) || "",
            name,
            # A JSON string on this protocol; kept as text and parsed at
            # export.
            function["arguments"]?.try(&.as_s?) || "{}")
        end
      end
    end
  end
end
