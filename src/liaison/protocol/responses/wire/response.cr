require "json"
require "./request"
require "../capabilities"
require "../../errors"
require "../../fields"
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
        # An explicit JSON `null` reads as absent.
        return unless any.try(&.as_h?)

        new(Fields.int(any, "input_tokens"),
          Fields.int(any, "output_tokens"),
          Fields.int(any, "total_tokens"))
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
        parsed = Fields.parse_object(body, NAME)

        from_any(parsed)
      end

      # Reads a response already parsed, such as the one a terminal stream
      # frame nests under `response`, by the same rules as a body.
      def self.from_any(parsed : JSON::Any) : Response
        raw = Fields.array(parsed, "output")
        unless raw
          raise MalformedResponseError.new(NAME, "response has no `output` array")
        end

        new(from_items(raw),
          id: Fields.string(parsed, "id"),
          model: Fields.string(parsed, "model"),
          status: Fields.string(parsed, "status"),
          usage: Usage.parse(Fields.at(parsed, "usage")))
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
        case Fields.string(any, "type")
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
        role = Fields.string(any, "role") || "assistant"
        parts = [] of Part
        refusals = [] of String

        Fields.array(any, "content").try &.each do |entry|
          case Fields.string(entry, "type")
          when "output_text", "input_text", "text"
            Fields.string(entry, "text").try { |text| parts << TextPart.new(text, role) }
          when "refusal"
            Fields.string(entry, "refusal").try { |reason| refusals << reason }
          end
        end

        into << MessageItem.new(role, parts) unless parts.empty?
        refusals.each { |reason| into << RefusalItem.new(reason) }
      end

      private def self.function_call(any : JSON::Any) : Item?
        name = Fields.string(any, "name")
        return unless name

        FunctionCallItem.new(
          Fields.string(any, "call_id") || Fields.string(any, "id") || "",
          name,
          # As on Chat Completions: a JSON string, or any other value as its
          # JSON text, so export judges it rather than this reading it as
          # empty.
          Fields.at(any, "arguments").try { |value| value.as_s? || value.to_json } || "{}")
      end

      # Keeps `encrypted_content` byte-identical, so the trace replays over
      # either OpenAI protocol.
      private def self.reasoning(any : JSON::Any) : Item
        summary = [] of String
        Fields.array(any, "summary").try &.each do |entry|
          Fields.string(entry, "text").try { |text| summary << text }
        end

        ReasoningItem.new(summary,
          id: Fields.string(any, "id"),
          encrypted_content: Fields.string(any, "encrypted_content"))
      end
    end
  end
end
