require "json"
require "./export"
require "./wire/response"
require "../../streaming/assembler"
require "../errors"
require "../fields"
require "../arguments"

module Liaison::Protocol::Anthropic
  # Frames from Anthropic's message stream, assembled into a
  # `Wire::Response`.
  #
  # The partial-form rule applies per block. A cut stream keeps the text and
  # thinking it received, since a prefix of prose is prose, and drops an
  # unfinished `tool_use`, whose `partial_json` means nothing until complete.
  # See `materialise`.
  #
  # Each block is rebuilt as the JSON object a buffered reply would carry and
  # read by `Wire::Response.from_content_block`, so streamed and buffered
  # blocks are read by the same rules.
  #
  # Blocks are keyed by their frames' `index` and sorted on output, not kept
  # in arrival order.
  class Assembler < ::Liaison::Streaming::Assembler
    # One content block being built.
    class Pending
      getter skeleton : JSON::Any
      property text : String
      property json : String
      property signature : String?
      property? closed : Bool

      def initialize(@skeleton : JSON::Any)
        @text = ""
        @json = ""
        @signature = nil
        @closed = false
      end

      def kind : String?
        Fields.string(@skeleton, "type")
      end
    end

    def initialize(@exporter : Exporter)
      @blocks = {} of Int32 => Pending
      @id = nil.as(String?)
      @model = nil.as(String?)
      @role = "assistant"
      @stop_reason = nil.as(String?)
      @stop_sequence = nil.as(String?)
      @usage = nil.as(Wire::Usage?)
      @terminal = false
    end

    def absorb(frame : Streaming::Sse::Frame, & : Streaming::Event ->) : Nil
      payload = Fields.parse_object?(frame.data)
      return unless payload

      case frame.name || Fields.string(payload, "type")
      when "content_block_delta"
        index = index_of(payload)
        return unless index
        pending = @blocks[index]?
        return unless pending

        delta = Fields.object(payload, "delta")
        return unless delta

        case Fields.string(delta, "type")
        when "text_delta"
          Fields.string(delta, "text").try do |text|
            pending.text += text
            yield Streaming::TextDelta.new(text)
          end
        when "thinking_delta"
          Fields.string(delta, "thinking").try do |text|
            pending.text += text
            yield Streaming::ReasoningDelta.new(text)
          end
        when "input_json_delta"
          # No event: argument fragments are not for watching.
          Fields.string(delta, "partial_json").try { |chunk| pending.json += chunk }
        when "signature_delta"
          # Replayed unmodified later; no event.
          Fields.string(delta, "signature").try { |value| pending.signature = value }
        end
      else
        record(frame, payload) { |event| yield event }
      end
    end

    def complete? : Bool
      @terminal
    end

    def finish : MPSH::Message
      @exporter.export_reply(response)
    end

    def response : Wire::Response
      Wire::Response.new(materialise,
        id: @id, model: @model, role: @role,
        stop_reason: @stop_reason, stop_sequence: @stop_sequence, usage: @usage)
    end

    # Frames that open, close or describe rather than fill.
    private def record(frame : Streaming::Sse::Frame, payload : JSON::Any,
                       & : Streaming::Event ->) : Nil
      case frame.name || Fields.string(payload, "type")
      when "message_start"       then Fields.object(payload, "message").try { |message| began(message) }
      when "content_block_start" then opened(payload) { |event| yield event }
      when "content_block_stop"  then closed(payload)
      when "message_delta"       then advanced(payload)
      when "message_stop"        then @terminal = true
      when "error"               then raise mid_stream(payload)
      end
    end

    # Identity and the input side of the token count.
    private def began(message : JSON::Any) : Nil
      @id = Fields.string(message, "id")
      @model = Fields.string(message, "model")
      @role = Fields.string(message, "role") || "assistant"
      Wire::Usage.parse(Fields.at(message, "usage")).try { |value| @usage = value }
    end

    # A block's skeleton, which every later delta for that index fills in.
    private def opened(payload : JSON::Any, & : Streaming::Event ->) : Nil
      index = index_of(payload)
      skeleton = Fields.object(payload, "content_block")
      return unless index && skeleton

      @blocks[index] = Pending.new(skeleton)
      return unless Fields.string(skeleton, "type") == "tool_use"

      # Announced the moment the block opens, because the name is here and
      # nowhere later — the deltas that follow carry only argument fragments.
      Fields.string(skeleton, "name").try { |name| yield Streaming::ToolCallStarted.new(name) }
    end

    private def closed(payload : JSON::Any) : Nil
      index_of(payload).try { |index| @blocks[index]?.try(&.closed=(true)) }
    end

    # The stop reason, and the final output-token count; `message_start`
    # carried the input side only.
    private def advanced(payload : JSON::Any) : Nil
      Fields.object(payload, "delta").try do |delta|
        Fields.string(delta, "stop_reason").try { |value| @stop_reason = value }
        Fields.string(delta, "stop_sequence").try { |value| @stop_sequence = value }
      end
      Wire::Usage.parse(Fields.at(payload, "usage")).try { |value| @usage = merged(value) }
    end

    # Closed blocks are materialised whatever they are. An open block is kept
    # only if it is text or thinking with content; an unfinished tool call is
    # dropped.
    private def materialise : Array(Wire::Block)
      @blocks.keys.sort!.compact_map do |index|
        pending = @blocks[index]
        next unless pending.closed? || salvageable?(pending)

        Wire::Response.from_content_block(rebuild(pending)).as(Wire::Block?)
      end
    end

    private def salvageable?(pending : Pending) : Bool
      case pending.kind
      when "text", "thinking" then !pending.text.empty?
      else                         false
      end
    end

    # Rebuilds the object the non-streamed reply would have carried.
    private def rebuild(pending : Pending) : JSON::Any
      fields = pending.skeleton.as_h.dup

      case pending.kind
      when "text"
        fields["text"] = JSON::Any.new(pending.text)
      when "thinking"
        fields["thinking"] = JSON::Any.new(pending.text)
        pending.signature.try { |value| fields["signature"] = JSON::Any.new(value) }
      when "tool_use", "server_tool_use"
        name = Fields.string(pending.skeleton, "name") || ""
        fields["input"] = JSON::Any.new(Arguments.object(pending.json, NAME, name))
      end

      JSON::Any.new(fields)
    end

    # Merges `message_delta`'s output count into `message_start`'s input
    # count, so usage matches a buffered reply's.
    private def merged(update : Wire::Usage) : Wire::Usage
      previous = @usage
      return update unless previous

      Wire::Usage.new(
        update.input_tokens || previous.input_tokens,
        update.output_tokens || previous.output_tokens)
    end

    private def index_of(payload : JSON::Any) : Int32?
      Fields.int(payload, "index")
    end

    private def mid_stream(payload : JSON::Any) : StreamError
      error = Fields.at(payload, "error")
      StreamError.new(NAME,
        Fields.string(error, "message") || "the provider sent an error frame",
        Fields.string(error, "type"))
    end
  end
end
