require "../mpsh/turns"

module Liaison::Capability
  # Which past reasoning blocks the caller wants replayed: a playback
  # preference, not a capability. A protocol that carries reasoning may still
  # be asked to receive none, and that is not annotated, since annotations
  # record loss the caller did not ask for. It governs replay only; replies
  # keep their reasoning.
  enum ReasoningRetention
    All            # replay everything the target can read; the default
    CompletedTurns # drop reasoning from closed turns, own and foreign alike
    None           # drop every reasoning block

    # `index` is the position of the containing message in the history.
    def retain?(index : Int32, completed : Set(Int32)) : Bool
      case self
      in All            then true
      in None           then false
      in CompletedTurns then !completed.includes?(index)
      end
    end
  end

  # Applies retention to a history at map time, returning the message indices
  # whose reasoning survives. Nothing is copied or mutated.
  #
  # `CompletedTurns` serves a model-specific requirement but is supplied by the
  # caller, not looked up in `Catalog`; see *Three identities, kept apart* in
  # `DEVELOPMENT.md`.
  module Retention
    extend self

    struct Plan
      getter dropped : Int32
      getter retain : Set(Int32)

      def initialize(@retain : Set(Int32), @dropped : Int32)
      end

      # Reasoning blocks in this message survive playback.
      def retain?(message_index : Int32) : Bool
        @retain.includes?(message_index)
      end
    end

    def plan(messages : Array(MPSH::Message), retention : ReasoningRetention) : Plan
      completed = retention.completed_turns? ? MPSH::Turns.completed_indices(messages) : Set(Int32).new
      retain = Set(Int32).new
      dropped = 0

      messages.each_with_index do |message, index|
        next unless message.content.any?(MPSH::ReasoningBlock)
        if retention.retain?(index, completed)
          retain << index
        else
          dropped += message.content.count { |block| block.is_a?(MPSH::ReasoningBlock) }
        end
      end

      Plan.new(retain, dropped)
    end
  end
end
