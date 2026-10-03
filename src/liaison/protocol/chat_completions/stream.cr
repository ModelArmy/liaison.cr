require "json"
require "./export"
require "./wire/response"
require "../../streaming/assembler"
require "../errors"

module Liaison::Protocol::ChatCompletions
  # Chunks from a Chat Completions stream, assembled into a `Wire::Response`.
  #
  # Nothing marks a tool call as finished: its arguments just stop growing.
  # So calls are materialised only once a `finish_reason` arrives, and a cut
  # stream yields its text and reasoning and no calls, even calls whose
  # arguments already parse: without a completion signal, the assembler does
  # not guess. Text and reasoning are kept: a prefix of prose is prose.
  #
  # The terminal `[DONE]` frame is not JSON. Usage arrives only when the
  # request sets `stream_options.include_usage`, in a final chunk with an
  # empty `choices` array.
  class Assembler < ::Liaison::Streaming::Assembler
    # One tool call being built. `id` and `name` arrive on the first fragment;
    # `arguments` accumulates across every fragment with the same index.
    class Pending
      property id : String?
      property name : String?
      property arguments : String

      def initialize
        @arguments = ""
      end
    end

    def initialize(@exporter : Exporter)
      @content = ""
      @reasoning = ""
      @calls = {} of Int32 => Pending
      @role = "assistant"
      @refusal = nil.as(String?)
      @finish_reason = nil.as(String?)
      @id = nil.as(String?)
      @model = nil.as(String?)
      @usage = nil.as(Wire::Usage?)
      @done = false
    end

    def absorb(frame : Streaming::Sse::Frame, & : Streaming::Event ->) : Nil
      if frame.data.strip == "[DONE]"
        @done = true
        return
      end

      payload = decode(frame.data)
      return unless payload
      raise mid_stream(payload) if payload["error"]?

      delta = absorb_metadata(payload)
      return unless delta

      @role = delta["role"]?.try(&.as_s?) || @role
      @refusal = delta["refusal"]?.try(&.as_s?) || @refusal

      delta["content"]?.try(&.as_s?).try do |text|
        next if text.empty?
        @content += text
        yield Streaming::TextDelta.new(text)
      end

      # Both spellings; see `Wire::Response.message`.
      reasoning = delta["reasoning_content"]?.try(&.as_s?) || delta["reasoning"]?.try(&.as_s?)
      reasoning.try do |text|
        next if text.empty?
        @reasoning += text
        yield Streaming::ReasoningDelta.new(text)
      end

      delta["tool_calls"]?.try(&.as_a?).try do |fragments|
        fragments.each do |fragment|
          announced = accumulate(fragment)
          announced.try { |name| yield Streaming::ToolCallStarted.new(name) }
        end
      end
    end

    # Whether a `finish_reason` or `[DONE]` arrived: generation ended, not
    # just the connection.
    def complete? : Bool
      @done || !@finish_reason.nil?
    end

    def finish : MPSH::Message
      @exporter.export_reply(response)
    end

    def response : Wire::Response
      choice = Wire::Choice.new(0,
        Wire::Response.from_message(rebuild),
        @finish_reason)

      Wire::Response.new([choice], id: @id, model: @model, usage: @usage)
    end

    # Folds a chunk's per-stream metadata into the assembler and returns the
    # delta left to absorb, or `nil` when the chunk carried no choice.
    private def absorb_metadata(payload : JSON::Any) : JSON::Any?
      @id = payload["id"]?.try(&.as_s?) || @id
      @model = payload["model"]?.try(&.as_s?) || @model
      Wire::Usage.parse(payload["usage"]?).try { |value| @usage = value }

      choice = payload["choices"]?.try(&.as_a?).try(&.first?)
      return unless choice

      choice["finish_reason"]?.try(&.as_s?).try { |value| @finish_reason = value }
      choice["delta"]?
    end

    # Folds one tool-call fragment into the call at its index, returning the
    # name when this fragment introduced the call, so `absorb` announces each
    # call once.
    private def accumulate(fragment : JSON::Any) : String?
      index = fragment["index"]?.try(&.as_i?) || 0
      pending = @calls[index] ||= Pending.new

      pending.id = fragment["id"]?.try(&.as_s?) || pending.id

      function = fragment["function"]?
      return unless function

      function["arguments"]?.try(&.as_s?).try { |chunk| pending.arguments += chunk }

      name = function["name"]?.try(&.as_s?)
      return unless name && pending.name.nil?

      pending.name = name
      name
    end

    # Rebuilds the message object a non-streamed reply would have carried.
    private def rebuild : JSON::Any
      fields = {} of String => JSON::Any
      fields["role"] = JSON::Any.new(@role)
      fields["content"] = JSON::Any.new(@content) unless @content.empty?
      fields["reasoning_content"] = JSON::Any.new(@reasoning) unless @reasoning.empty?
      @refusal.try { |value| fields["refusal"] = JSON::Any.new(value) }

      calls = tool_calls
      fields["tool_calls"] = JSON::Any.new(calls) unless calls.empty?

      JSON::Any.new(fields)
    end

    # The calls, only if generation finished; see the class note.
    private def tool_calls : Array(JSON::Any)
      return [] of JSON::Any unless complete?

      @calls.keys.sort!.compact_map do |index|
        pending = @calls[index]
        name = pending.name
        next unless name

        JSON::Any.new({
          "id"       => JSON::Any.new(pending.id || ""),
          "type"     => JSON::Any.new("function"),
          "function" => JSON::Any.new({
            "name"      => JSON::Any.new(name),
            "arguments" => JSON::Any.new(pending.arguments.presence || "{}"),
          } of String => JSON::Any),
        } of String => JSON::Any).as(JSON::Any?)
      end
    end

    private def decode(data : String) : JSON::Any?
      JSON.parse(data)
    rescue JSON::ParseException
      nil
    end

    private def mid_stream(payload : JSON::Any) : StreamError
      error = payload["error"]?
      StreamError.new(NAME,
        error.try(&.["message"]?).try(&.as_s?) || "the provider sent an error chunk",
        error.try(&.["type"]?).try(&.as_s?))
    end
  end
end
