require "json"
require "./export"
require "./wire/response"
require "../../streaming/assembler"
require "../errors"

module Liaison::Protocol::Gemini
  # Chunks from `:streamGenerateContent?alt=sse`, assembled into a
  # `Wire::Response`.
  #
  # Every chunk is a whole response whose parts are fragments: text arrives as
  # `{"text": "Mount "}` then `{"text": "Everest"}`, with no finished units and
  # no terminal assembly. So text is concatenated, and a `functionCall` part is
  # taken whole and never merged. Each chunk is read by
  # `Wire::Response.from_any`, so merging works on parts already identified.
  class Assembler < ::Liaison::Streaming::Assembler
    def initialize(@exporter : Exporter)
      @parts = [] of Wire::Part
      @role = "model"
      @finish_reason = nil.as(String?)
      @model_version = nil.as(String?)
      @usage = nil.as(Wire::Usage?)
      @terminal = false
    end

    def absorb(frame : Streaming::Sse::Frame, & : Streaming::Event ->) : Nil
      payload = decode(frame.data)
      return unless payload

      # A mid-stream failure is an `error` object in place of a candidate.
      raise mid_stream(payload) if payload["error"]?

      # Usually on the last chunk; kept whenever seen.
      payload["modelVersion"]?.try(&.as_s?).try { |value| @model_version = value }
      Wire::Usage.parse(payload["usageMetadata"]?).try { |value| @usage = value }

      return unless payload["candidates"]?
      candidate = Wire::Response.from_any(payload).candidate
      return unless candidate

      @role = candidate.content.role
      candidate.finish_reason.try do |reason|
        @finish_reason = reason
        @terminal = true
      end

      candidate.content.parts.each do |part|
        case part
        when Wire::TextPart
          yield Streaming::TextDelta.new(part.text)
        when Wire::ThoughtPart
          part.text.try { |text| yield Streaming::ReasoningDelta.new(text) }
        when Wire::FunctionCallPart
          yield Streaming::ToolCallStarted.new(part.name)
        end

        merge(part)
      end
    end

    # Whether a finish reason arrived. It is the only terminator, so
    # `MAX_TOKENS` is a complete stream reporting a truncated answer.
    def complete? : Bool
      @terminal
    end

    def finish : MPSH::Message
      @exporter.export_reply(response)
    end

    def response : Wire::Response
      Wire::Response.new(
        [Wire::Candidate.new(0, Wire::Content.new(@role, @parts), @finish_reason)],
        model_version: @model_version,
        usage: @usage)
    end

    # Appends a part, merging it into the previous one when both are text of
    # the same kind. Only the last part is ever merged, so the order of
    # thinking, text and calls is kept.
    private def merge(part : Wire::Part) : Nil
      last = @parts.last?

      case part
      when Wire::TextPart
        if last.is_a?(Wire::TextPart)
          @parts[-1] = Wire::TextPart.new(last.text + part.text)
          return
        end
      when Wire::ThoughtPart
        if last.is_a?(Wire::ThoughtPart)
          # The newest signature wins, and an absent one never erases one
          # already seen.
          @parts[-1] = Wire::ThoughtPart.new(
            "#{last.text}#{part.text}",
            part.signature || last.signature)
          return
        end
      end

      @parts << part
    end

    # A chunk that does not parse is skipped. If it held the finish reason,
    # `complete?` stays false and `Client#send` marks the reply
    # `Interrupted`.
    private def decode(data : String) : JSON::Any?
      JSON.parse(data)
    rescue JSON::ParseException
      nil
    end

    private def mid_stream(payload : JSON::Any) : StreamError
      error = payload["error"]?
      StreamError.new(NAME,
        error.try(&.["message"]?).try(&.as_s?) || "the provider sent an error chunk",
        error.try(&.["status"]?).try(&.as_s?))
    end
  end
end
