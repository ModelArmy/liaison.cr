require "./policy"
require "./structural"
require "../mpsh/block"

module Liaison::Capability
  # The compensation carrier, for the three protocols whose tool results take
  # text only. Non-text content is lifted out of a tool result, a marker is
  # left where it stood, and the content goes in a synthesized user message
  # after the run of results; export reverses it.
  #
  # This module holds the rule and never sees a wire type: callers pass parts
  # in and build their own message. See *The compensation carrier, both
  # directions* in `DEVELOPMENT.md`.
  module Carrier
    extend self

    # The marker left where lifted content stood. One constant, matched exactly
    # on export by every protocol, since a session mapped by one may be
    # exported by another. Never localized: the exporter reads it, not the
    # model.
    PLACEHOLDER = "[liaison: content returned separately in the following message]"

    # ---- Mapping: request out ------------------------------------------------

    # Emits the buffered carrier, if any, and clears the buffer.
    #
    # Call it at anything that is not a tool result: a user message, an
    # assistant message, or the end of the request. Strict servers reject a
    # carrier between the tool results answering one turn, so one carrier may
    # hold several results' content.
    #
    # The block receives the parts and appends its protocol's message. It is
    # called only when there is something to carry.
    def flush(pending : Array(T), report : Report, & : Array(T) -> Nil) : Nil forall T
      return if pending.empty?

      report.record(
        Structural.outcome(Structural::Adaptation::DeferCompensationCarrier),
        "compensation carrier deferred past #{pending.size} tool result(s)")

      yield pending.dup
      pending.clear
    end

    # ---- Export: request back in ---------------------------------------------

    # Whether a message following a run of tool results is a carrier rather
    # than genuine input. A guess, narrowed by three signals in turn:
    # `synthetic` (decisive, but lost once archived), a marker still open in
    # the run, and no text of its own, which the block tests per part. A
    # genuine user message holding only an image is misread.
    #
    # `eligible` is each caller's own precondition, such as Gemini's
    # `role: "user"`. It is checked after `synthetic`, so a synthetic message
    # that fails it is still a carrier.
    def carrier?(run : Array(MPSH::ToolResultBlock), synthetic : Bool,
                 parts : Array(T), eligible : Bool = true,
                 & : T -> Bool) : Bool forall T
      return false if run.empty?
      return true if synthetic
      return false unless eligible
      return false unless run.any? { |result| placeholders(result) > 0 }

      parts.none? { |part| yield part }
    end

    # Returns carrier content to the results that referenced it. Each result
    # takes as many parts as it left markers, in order, so one carrier can
    # serve a run of results.
    #
    # Each part is written to its own marker's position, found before any
    # writing; replacement never resizes the array. A part the block converts
    # to `nil` leaves its marker standing where it was.
    def absorb(run : Array(MPSH::ToolResultBlock), parts : Array(T),
               & : T -> MPSH::Block?) : Nil forall T
      queue = parts.dup

      run.each do |result|
        marker_indices(result).each do |index|
          part = queue.shift?
          break unless part
          block = yield part
          result.content[index] = block if block
        end
      end
    end

    # How many markers this result is still holding open.
    def placeholders(result : MPSH::ToolResultBlock) : Int32
      marker_indices(result).size
    end

    # The positions of those markers, in order.
    def marker_indices(result : MPSH::ToolResultBlock) : Array(Int32)
      indices = [] of Int32

      result.content.each_with_index do |block, index|
        indices << index if block.is_a?(MPSH::TextBlock) && block.text == PLACEHOLDER
      end

      indices
    end

    # Splits a tool result's wire text back into blocks at each marker, so a
    # carrier can be absorbed into the right positions. Splits on the marker,
    # not on newlines, which genuine tool output contains.
    def split(body : String) : Array(MPSH::Block)
      return [] of MPSH::Block if body.empty?

      blocks = [] of MPSH::Block
      segments = body.split(PLACEHOLDER)

      segments.each_with_index do |segment, index|
        trimmed = segment.strip('\n')
        blocks << MPSH::TextBlock.new(trimmed) unless trimmed.empty?
        # Every split point but the last trailing one had a marker.
        blocks << MPSH::TextBlock.new(PLACEHOLDER) if index < segments.size - 1
      end

      blocks
    end
  end
end
