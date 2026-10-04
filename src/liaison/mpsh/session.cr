require "./message"
require "./annotation"

module Liaison::MPSH
  # Mints MPSH call ids, `mc_<epoch-ms>_<counter>`. MPSH mints its own because
  # Gemini has no call ids to store: it pairs a call and its response by name
  # and order.
  module Ids
    @@counter = Atomic(Int64).new(0)

    def self.call_id : String
      "mc_#{Time.utc.to_unix_ms}_#{@@counter.add(1)}"
    end
  end

  # The canonical session: a system prompt, a flat list of messages, and
  # annotations: each block a provider was sent in degraded form, once per
  # provider, by message index.
  #
  # It has no serialization of its own. `Archive` stores it and the mappers
  # render it, both from outside, so storage form never becomes wire form.
  class Session
    property system_prompt : String?
    getter messages : Array(Message)
    getter annotations : Array(Annotation)

    def initialize(@system_prompt : String? = nil,
                   @messages : Array(Message) = [] of Message,
                   @annotations : Array(Annotation) = [] of Annotation)
    end

    def <<(message : Message) : self
      @messages << message
      self
    end

    def annotate(note : Annotation) : Nil
      @annotations << note
    end

    # A copy of the lists that shares the message objects, for handing the same
    # history to a second provider.
    def fork : Session
      Session.new(@system_prompt, @messages.dup, @annotations.dup)
    end

    def size : Int32
      @messages.size
    end
  end
end
