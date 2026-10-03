require "../mpsh/annotation"

module Liaison::Capability
  # Which outcomes a caller accepts, set per `Client` and overridable per
  # call. Mappers never decide this.
  enum Policy
    Strict       # nothing worse than Restructured
    Compensating # Compensated allowed; Degraded is not
    Lenient      # Degraded allowed, each occurrence recorded

    def worst_allowed : MPSH::Outcome
      case self
      in Strict       then MPSH::Outcome::Restructured
      in Compensating then MPSH::Outcome::Compensated
      in Lenient      then MPSH::Outcome::Degraded
      end
    end

    def permits?(outcome : MPSH::Outcome) : Bool
      outcome <= worst_allowed
    end
  end

  # Raised when an outcome exceeds the policy, or a block cannot be mapped at
  # all. Nothing is sent.
  class RefusedError < Exception
    getter outcome : MPSH::Outcome
    getter provider : String
    getter block_kind : MPSH::BlockKind?

    def initialize(@provider : String, detail : String,
                   @block_kind : MPSH::BlockKind? = nil,
                   @outcome : MPSH::Outcome = MPSH::Outcome::Refused)
      super("#{@provider}: #{detail}")
    end
  end

  # What one mapping cost: every lossy or synthesized outcome as an
  # annotation, and the worst outcome seen. Synthesized content itself exists
  # only in the outgoing request.
  #
  # `Client` does not copy annotations onto the session; a caller keeping an
  # audit trail calls `Session#annotate`.
  class Report
    getter provider : String
    getter policy : Policy
    getter annotations : Array(MPSH::Annotation)

    def initialize(@provider : String, @policy : Policy = Policy::Compensating)
      @annotations = [] of MPSH::Annotation
      @worst = MPSH::Outcome::Exact
      @reasoning_dropped = 0
    end

    getter worst : MPSH::Outcome

    # Reasoning blocks omitted at the caller's request (`ReasoningRetention`).
    # A count rather than annotations, since requested trimming is not loss.
    property reasoning_dropped : Int32

    # Whether the reply arrived as a stream. A plain fact rather than an
    # annotation: a streamed and a buffered reply are the same message, so
    # nothing is lost by not streaming, and `record` would raise on a
    # `Degraded` fallback under the default policy.
    property? streamed : Bool = false

    # Records an outcome: raises `RefusedError` if the policy does not permit
    # it, and annotates it if lossy or synthesized. Every mapper reports every
    # outcome here.
    def record(outcome : MPSH::Outcome, detail : String,
               message_index : Int32? = nil, block_kind : MPSH::BlockKind? = nil) : MPSH::Outcome
      @worst = outcome if outcome > @worst

      unless policy.permits?(outcome)
        raise RefusedError.new(provider, "#{detail} (#{outcome} exceeds policy #{policy})", block_kind, outcome)
      end

      if outcome.lossy? || outcome.synthesizes?
        @annotations << MPSH::Annotation.new(outcome, provider, detail, message_index, block_kind)
      end
      outcome
    end
  end
end
