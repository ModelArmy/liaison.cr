require "json"
require "./request"
require "../capabilities"
require "../../errors"
require "../../../mpsh/meta"

module Liaison::Protocol::Gemini
  # The response half of the wire form. `candidates[]` holds alternative
  # answers; this shard never sets `candidateCount`, so it reads the first.
  #
  # A part is identified by which key it has (`text`, `functionCall`,
  # `inlineData`), not by a `type` field, and a thought is a `text` part with
  # `thought: true`. The flag is checked first: read the other way, every
  # thought becomes ordinary prose.
  module Wire
    struct Usage
      getter prompt_tokens : Int32?
      getter candidates_tokens : Int32?
      getter thoughts_tokens : Int32?
      getter total_tokens : Int32?

      def initialize(@prompt_tokens : Int32? = nil, @candidates_tokens : Int32? = nil,
                     @thoughts_tokens : Int32? = nil, @total_tokens : Int32? = nil)
      end

      def self.parse(any : JSON::Any?) : Usage?
        # `as_h?` rather than a nil check, so an explicit JSON `null` reads as
        # absent instead of being indexed as a hash.
        fields = any.try(&.as_h?)
        return unless fields

        new(fields["promptTokenCount"]?.try(&.as_i?),
          fields["candidatesTokenCount"]?.try(&.as_i?),
          fields["thoughtsTokenCount"]?.try(&.as_i?),
          fields["totalTokenCount"]?.try(&.as_i?))
      end

      def to_metadata : MPSH::Object
        object = MPSH::Object.new
        @prompt_tokens.try { |value| object["promptTokenCount"] = value.to_i64 }
        @candidates_tokens.try { |value| object["candidatesTokenCount"] = value.to_i64 }
        @thoughts_tokens.try { |value| object["thoughtsTokenCount"] = value.to_i64 }
        @total_tokens.try { |value| object["totalTokenCount"] = value.to_i64 }
        object
      end
    end

    struct Candidate
      getter index : Int32
      getter content : Content
      getter finish_reason : String?

      def initialize(@index : Int32, @content : Content, @finish_reason : String? = nil)
      end
    end

    struct Response
      getter model_version : String?
      getter candidates : Array(Candidate)
      getter usage : Usage?

      def initialize(@candidates : Array(Candidate), @model_version : String? = nil,
                     @usage : Usage? = nil)
      end

      # The one answer requested; see the note above.
      def candidate : Candidate?
        @candidates.first?
      end

      def self.from_json(body : String) : Response
        parsed = begin
          JSON.parse(body)
        rescue error : JSON::ParseException
          raise MalformedResponseError.new(NAME, "response body is not JSON: #{error.message}")
        end

        from_any(parsed)
      end

      # Reads a response already parsed. Every stream chunk is a whole
      # response, so the assembler reads each with this, by the same rules.
      def self.from_any(parsed : JSON::Any) : Response
        raw = parsed["candidates"]?.try(&.as_a?)
        unless raw
          raise MalformedResponseError.new(NAME, "response has no `candidates` array")
        end

        new(raw.map_with_index { |entry, index| candidate(entry, index) },
          model_version: parsed["modelVersion"]?.try(&.as_s?),
          usage: Usage.parse(parsed["usageMetadata"]?))
      end

      private def self.candidate(any : JSON::Any, position : Int32) : Candidate
        body = any["content"]?
        parts = [] of Part
        body.try(&.["parts"]?).try(&.as_a?).try &.each do |entry|
          part(entry).try { |value| parts << value }
        end

        Candidate.new(
          any["index"]?.try(&.as_i?) || position,
          # `model`, not `assistant`.
          Content.new(body.try(&.["role"]?).try(&.as_s?) || "model", parts),
          any["finishReason"]?.try(&.as_s?))
      end

      # Identified by key, with the thought flag checked first, since a
      # thought part also carries `text`.
      private def self.part(any : JSON::Any) : Part?
        return thought(any) if any["thought"]?.try(&.as_bool?)

        if call = any["functionCall"]?
          return function_call(call, any["thoughtSignature"]?.try(&.as_s?))
        end

        # The REST API sends camelCase; some compatible servers send the
        # snake_case the request side writes.
        if data = any["inlineData"]? || any["inline_data"]?
          return inline_data(data)
        end

        any["text"]?.try(&.as_s?).try { |text| TextPart.new(text) }
      end

      private def self.function_call(any : JSON::Any, thought_signature : String?) : Part?
        name = any["name"]?.try(&.as_s?)
        return unless name

        # `args` is structured; re-serialized to raw JSON text and parsed once,
        # on export. There is no id to read. `thought_signature` is passed in
        # because it sits beside `functionCall` on the enclosing part, not
        # inside it.
        FunctionCallPart.new(name,
          (any["args"]? || JSON::Any.new({} of String => JSON::Any)).to_json,
          thought_signature)
      end

      private def self.inline_data(any : JSON::Any) : Part?
        mime = any["mimeType"]?.try(&.as_s?) || any["mime_type"]?.try(&.as_s?)
        data = any["data"]?.try(&.as_s?)
        return unless mime && data

        InlineDataPart.new(mime, data)
      end

      private def self.thought(any : JSON::Any) : Part
        text = any["text"]?.try(&.as_s?)
        ThoughtPart.new(text, any["thoughtSignature"]?.try(&.as_s?))
      end
    end
  end
end
