require "./block"

module Liaison::MPSH
  # Two roles. `system`, `developer`, `tool` and `model` are provider spellings
  # and are resolved at map time, in both directions.
  enum Role
    User
    Assistant
  end

  # How a turn finished. Stored on the message because a reloaded session must
  # know its last turn was cut, and a `Capability::Report` is never archived.
  #
  # Settable rather than derived from `provider_metadata`: `Interrupted` has no
  # vendor field to derive from, since a dropped stream is known only by its
  # missing terminal frame.
  #
  # The cause tells the caller what to do next (await input, back off, retry).
  # `Repair` treats every value but `Complete` alike.
  enum Ending
    Complete    # the model finished
    Truncated   # the model stopped short: an output cap, a resource limit
    Stopped     # the caller asked, through `Streaming::Turn#stop`
    Interrupted # the stream ended without its terminal frame

    # Whether the turn needs `Repair` before the session is built on again.
    def cut? : Bool
      !complete?
    end
  end

  # Who produced an assistant turn. Archived; mapping never reads it.
  struct Provenance
    getter provider : String
    getter model : String
    getter bias : String?

    def initialize(@provider : String, @model : String, @bias : String? = nil)
    end
  end

  class Message
    include ProviderScoped

    getter role : Role
    getter content : Array(Block)
    getter provenance : Provenance?

    # `Complete` unless something says otherwise: an exporter reading its
    # protocol's own stop reason, or `Client` observing how a stream ended.
    property ending : Ending = Ending::Complete

    def initialize(@role : Role, @content : Array(Block) = [] of Block,
                   @provenance : Provenance? = nil)
    end

    def self.user(text : String)
      new(Role::User, [TextBlock.new(text).as(Block)])
    end

    def self.assistant(text : String, provenance : Provenance? = nil)
      new(Role::Assistant, [TextBlock.new(text).as(Block)], provenance)
    end

    def text : String
      content.compact_map { |block| block.as?(TextBlock).try &.text }.join("\n\n")
    end
  end
end
