require "./block"

module Liaison::MPSH
  # The five outcomes, ordered by fidelity. A policy reads "nothing worse than
  # X", so the order is compared rather than looked up.
  enum Outcome
    Exact        # native support, direct translation
    Restructured # same information, different shape
    Compensated  # meaning preserved by synthesizing messages; never stored
    Degraded     # information lost, substitute used; recorded
    Refused      # cannot map; fail loudly, send nothing

    def lossy?
      self >= Degraded
    end

    def synthesizes?
      self == Compensated
    end
  end

  # A recorded fidelity outcome, kept off the conversation: never linearized
  # and never sent to a provider. Lets a caller audit afterwards what a
  # provider was not sent.
  struct Annotation
    getter outcome : Outcome
    getter provider : String
    getter detail : String
    getter message_index : Int32?
    getter block_kind : BlockKind?
    getter at : Time

    def initialize(@outcome : Outcome, @provider : String, @detail : String,
                   @message_index : Int32? = nil, @block_kind : BlockKind? = nil,
                   @at : Time = Time.utc)
    end

    def to_s(io : IO) : Nil
      io << outcome << " [" << provider << "] " << detail
      if k = block_kind
        io << " (" << k << ")"
      end
    end
  end
end
