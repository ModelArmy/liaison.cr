require "./message"
require "./session"

module Liaison::MPSH
  # Makes a cut turn safe to build on, so the session holds no tool call
  # without its result. A dangling call is rejected outright by some
  # protocols, so a session carrying one is not portable.
  #
  # Pure MPSH, with no protocol, provider or transport, so a session reloaded
  # from an archive can be repaired without any.
  #
  # Calls are dropped and text is kept. A text prefix is a valid short answer;
  # a partial call cannot be dispatched, and a complete-looking set may be half
  # of a parallel plan. The streaming assemblers already omit calls they
  # cannot vouch for, so this mostly serves a non-streamed reply truncated
  # mid-plan.
  module Repair
    extend self

    # Whether the message is cut and holds tool calls. A complete message with
    # unanswered calls is not this module's to mend; see `sendable?`.
    def needed?(message : Message) : Bool
      message.ending.cut? && message.content.any?(ToolCallBlock)
    end

    # The message without its tool calls, as a new `Message`, or `nil` when
    # nothing else survives. The original is untouched, so a caller can still
    # display what arrived.
    def repaired(message : Message) : Message?
      return message unless needed?(message)

      # ameba:disable Style/IsAFilter - Need T in Array(T) to retain ToolCallBlock
      kept = message.content.reject(&.is_a?(ToolCallBlock))
      return if kept.empty?

      repaired = Message.new(message.role, kept, message.provenance)
      repaired.ending = message.ending
      repaired.provider_metadata = message.provider_metadata
      repaired
    end

    # Repairs a session in place, returning whether anything changed. For
    # archives written before repair ran. Removes only messages it emptied; a
    # message that arrived empty is left as it was.
    def repair!(session : Session) : Bool
      emptied = [] of Int32
      changed = false

      session.messages.each_with_index do |message, index|
        next unless needed?(message)
        changed = true
        if fixed = repaired(message)
          session.messages[index] = fixed
        else
          emptied << index
        end
      end

      emptied.reverse_each { |index| session.messages.delete_at(index) }
      changed
    end

    # Whether every tool call has a result in the session, server-executed
    # calls included.
    def sendable?(session : Session) : Bool
      answered = Set(String).new
      session.messages.each do |message|
        message.content.each do |block|
          answered << block.call_id if block.is_a?(ToolResultBlock)
        end
      end

      session.messages.all? do |message|
        message.content.all? do |block|
          !block.is_a?(ToolCallBlock) || answered.includes?(block.call_id)
        end
      end
    end
  end
end
