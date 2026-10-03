require "json"
require "./request"
require "../capabilities"
require "../../errors"
require "../../../mpsh/meta"

module Liaison::Protocol::Responses
  # The response half of the wire form. `output[]` holds the reply's own
  # parts (reasoning, a message, one `function_call` per call), not
  # alternatives, so it is read entire and in order. Its items are the
  # request-side `Item` types.
  module Wire
    struct Usage
      getter input_tokens : Int32?
      getter output_tokens : Int32?
      getter total_tokens : Int32?

      def initialize(@input_tokens : Int32? = nil, @output_tokens : Int32? = nil,
                     @total_tokens : Int32? = nil)
      end

      def self.parse(any : JSON::Any?) : Usage?
        # `as_h?` rather than a nil check, so an explicit JSON `null` reads as
        # absent instead of being indexed as a hash.
        fields = any.try(&.as_h?)
        return unless fields

        new(fields["input_tokens"]?.try(&.as_i?),
          fields["output_tokens"]?.try(&.as_i?),
          fields["total_tokens"]?.try(&.as_i?))
      end

      def to_metadata : MPSH::Object
        object = MPSH::Object.new
        @input_tokens.try { |value| object["input_tokens"] = value.to_i64 }
        @output_tokens.try { |value| object["output_tokens"] = value.to_i64 }
        @total_tokens.try { |value| object["total_tokens"] = value.to_i64 }
        object
      end
    end

    struct Response
      getter id : String?
      getter model : String?
      getter status : String?
      getter output : Array(Item)
      getter usage : Usage?

      def initialize(@output : Array(Item), @id : String? = nil, @model : String? = nil,
                     @status : String? = nil, @usage : Usage? = nil)
      end

      def self.from_json(body : String) : Response
        parsed = begin
          JSON.parse(body)
        rescue error : JSON::ParseException
          raise MalformedResponseError.new(NAME, "response body is not JSON: #{error.message}")
        end

        from_any(parsed)
      end

      # Reads a response already parsed, such as the one a terminal stream
      # frame nests under `response`, by the same rules as a body.
      def self.from_any(parsed : JSON::Any) : Response
        raw = parsed["output"]?.try(&.as_a?)
        unless raw
          raise MalformedResponseError.new(NAME, "response has no `output` array")
        end

        new(from_items(raw),
          id: parsed["id"]?.try(&.as_s?),
          model: parsed["model"]?.try(&.as_s?),
          status: parsed["status"]?.try(&.as_s?),
          usage: Usage.parse(parsed["usage"]?))
      end

      # Reads items with no envelope, for an assembler collecting finished
      # items; the same code as a full response.
      def self.from_items(raw : Array(JSON::Any)) : Array(Item)
        output = [] of Item
        raw.each { |entry| items(entry, output) }
        output
      end

      # One wire item may yield several `Item`s: a message holding output text
      # and a refusal becomes a message and a refusal item.
      private def self.items(any : JSON::Any, into : Array(Item)) : Nil
        case any["type"]?.try(&.as_s?)
        when "message"
          message(any, into)
        when "function_call"
          function_call(any).try { |item| into << item }
        when "reasoning"
          into << reasoning(any)
        end
        # Unknown item types are dropped, not raised on, so a provider adding
        # one does not break this reader.
      end

      private def self.message(any : JSON::Any, into : Array(Item)) : Nil
        role = any["role"]?.try(&.as_s?) || "assistant"
        parts = [] of Part
        refusals = [] of String

        any["content"]?.try(&.as_a?).try &.each do |entry|
          case entry["type"]?.try(&.as_s?)
          when "output_text", "input_text", "text"
            entry["text"]?.try(&.as_s?).try { |text| parts << TextPart.new(text, role) }
          when "refusal"
            entry["refusal"]?.try(&.as_s?).try { |reason| refusals << reason }
          end
        end

        into << MessageItem.new(role, parts) unless parts.empty?
        refusals.each { |reason| into << RefusalItem.new(reason) }
      end

      private def self.function_call(any : JSON::Any) : Item?
        name = any["name"]?.try(&.as_s?)
        return unless name

        FunctionCallItem.new(
          any["call_id"]?.try(&.as_s?) || any["id"]?.try(&.as_s?) || "",
          name,
          # As on Chat Completions: a JSON string, or any other value as its
          # JSON text, so export judges it rather than this reading it as
          # empty.
          any["arguments"]?.try { |value| value.as_s? || value.to_json } || "{}")
      end

      # Keeps `encrypted_content` byte-identical, so the trace replays over
      # either OpenAI protocol.
      private def self.reasoning(any : JSON::Any) : Item
        summary = [] of String
        any["summary"]?.try(&.as_a?).try &.each do |entry|
          entry["text"]?.try(&.as_s?).try { |text| summary << text }
        end

        ReasoningItem.new(summary,
          id: any["id"]?.try(&.as_s?),
          encrypted_content: any["encrypted_content"]?.try(&.as_s?))
      end
    end
  end
end
