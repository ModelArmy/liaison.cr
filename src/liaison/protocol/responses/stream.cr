require "json"
require "./export"
require "./wire/response"
require "../../streaming/assembler"
require "../errors"

module Liaison::Protocol::Responses
  # Frames from the Responses protocol, assembled into a `Wire::Response`.
  #
  # Deltas become events and are not stored. `response.output_item.done`
  # frames each carry one finished item, which is accumulated, so a cut
  # stream's reply holds only complete items and never an unfinished call.
  # `response.completed` carries the whole response and replaces the
  # accumulation.
  #
  # `accumulated` remains available after the terminal frame, so specs can
  # compare this assembly against the vendor's own on real transcripts.
  class Assembler < ::Liaison::Streaming::Assembler
    def initialize(@exporter : Exporter)
      @items = [] of JSON::Any
      @completed = nil.as(JSON::Any?)
    end

    def absorb(frame : Streaming::Sse::Frame, & : Streaming::Event ->) : Nil
      payload = decode(frame.data)
      return unless payload

      # Prefers the `event:` line and falls back to the payload's `type`, for
      # servers that send unnamed frames.
      kind = frame.name || payload["type"]?.try(&.as_s?)

      # What a watcher sees is handled here and what the reply is made of in
      # `record`; nothing is in both.
      case kind
      when "response.output_text.delta"
        if text = delta(payload)
          yield Streaming::TextDelta.new(text)
        end
      when "response.reasoning_summary_text.delta"
        if text = delta(payload)
          yield Streaming::ReasoningDelta.new(text)
        end
      when "response.output_item.added"
        if name = tool_name(payload)
          yield Streaming::ToolCallStarted.new(name)
        end
      else
        record(kind, payload)
      end
    end

    # Frames that change what the reply will be, and are never watched.
    private def record(kind : String?, payload : JSON::Any) : Nil
      case kind
      when "response.output_item.done"
        payload["item"]?.try { |item| @items << item }
      when "response.completed", "response.incomplete"
        # `incomplete` is terminal too: the model hit a limit, and its
        # `status` reaches the reply's metadata.
        @completed = payload["response"]?
      when "response.failed"
        raise failure(payload)
      when "error"
        raise mid_stream(payload)
      end
    end

    def complete? : Bool
      !@completed.nil?
    end

    def finish : MPSH::Message
      @exporter.export_reply(response)
    end

    # What `finish` will translate: the vendor's assembly when there is one,
    # ours when the stream did not get that far.
    def response : Wire::Response
      if completed = @completed
        Wire::Response.from_any(completed)
      else
        accumulated
      end
    end

    # Only the items that finished arriving, with `status` `incomplete`.
    def accumulated : Wire::Response
      Wire::Response.new(Wire::Response.from_items(@items), status: "incomplete")
    end

    # A frame that does not parse is skipped. A lost delta was never
    # authoritative; a lost terminal frame leaves `complete?` false, so
    # `Client#send` marks the reply `Interrupted`.
    private def decode(data : String) : JSON::Any?
      JSON.parse(data)
    rescue JSON::ParseException
      nil
    end

    private def delta(payload : JSON::Any) : String?
      payload["delta"]?.try(&.as_s?)
    end

    # The name, and deliberately nothing else — see `Streaming::ToolCallStarted`.
    private def tool_name(payload : JSON::Any) : String?
      item = payload["item"]?
      return unless item
      return unless item["type"]?.try(&.as_s?) == "function_call"
      item["name"]?.try(&.as_s?)
    end

    private def failure(payload : JSON::Any) : StreamError
      error = payload["response"]?.try(&.["error"]?)
      StreamError.new(NAME,
        error.try(&.["message"]?).try(&.as_s?) || "the provider reported a failed response",
        error.try(&.["code"]?).try(&.as_s?))
    end

    private def mid_stream(payload : JSON::Any) : StreamError
      StreamError.new(NAME,
        payload["message"]?.try(&.as_s?) || "the provider sent an error frame",
        payload["code"]?.try(&.as_s?))
    end
  end
end
