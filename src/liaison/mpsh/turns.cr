require "./message"
require "./block"

module Liaison::MPSH
  # A turn runs from one genuine user input to the next. A tool result is a
  # user-role message but not input, so one turn may hold call, result, call,
  # result. Segmenting on role instead would cut a tool exchange in half.
  struct Turn
    # Inclusive range of message indices.
    getter first : Int32
    getter last : Int32
    getter? completed : Bool

    def initialize(@first : Int32, @last : Int32, @completed : Bool)
    end

    def includes?(index : Int32) : Bool
      index >= first && index <= last
    end

    def size : Int32
      last - first + 1
    end
  end

  module Turns
    extend self

    # A user message that carries anything other than tool results is a real
    # input and opens a new turn.
    def input?(message : Message) : Bool
      return false unless message.role.user?
      return true if message.content.empty?
      message.content.any? { |block| !block.is_a?(ToolResultBlock) }
    end

    # Splits messages into turns. Every turn but the last is completed.
    # Retention rules skip the last, which keeps a reasoning block between a
    # tool call and its result, where some providers require it replayed.
    def segment(messages : Array(Message)) : Array(Turn)
      starts = [] of Int32
      messages.each_with_index do |message, index|
        starts << index if input?(message)
      end
      # History that opens with an assistant message still forms a turn.
      starts.unshift(0) if starts.empty? || starts.first != 0

      turns = [] of Turn
      starts.each_with_index do |start, position|
        last = (position + 1 < starts.size) ? starts[position + 1] - 1 : messages.size - 1
        next if last < start
        turns << Turn.new(start, last, position + 1 < starts.size)
      end
      turns
    end

    def completed_indices(messages : Array(Message)) : Set(Int32)
      segment(messages).each_with_object(Set(Int32).new) do |turn, acc|
        next unless turn.completed?
        (turn.first..turn.last).each { |index| acc << index }
      end
    end
  end
end
