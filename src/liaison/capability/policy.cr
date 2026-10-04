require "../mpsh/annotation"
require "../mpsh/session"

module Liaison::Capability
  # Which outcomes a caller accepts, set per `Client` and overridable per
  # call. Mappers never decide this.
  enum Policy
    Strict       # nothing worse than Restructured
    Compensating # Compensated allowed; Degraded is not
    Lenient      # Degraded allowed, each degraded block recorded

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
  # Only content losses outlive the call, through `annotate`. Compensations,
  # sequence adaptations and request options describe this request alone.
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

    # Adds this call's content losses to `session`'s annotations, each once.
    #
    # A content loss is a `Degraded` outcome on a block of the history, so it
    # carries a `message_index`. One is identified by outcome, provider,
    # message index and block kind; `session` keeps as many of each as the
    # largest single report has held, which counts two degraded blocks of one
    # message as two. Re-sending the same history adds nothing; another
    # provider losing the same block adds its own. `Client#send` calls this
    # after each exchange that returns.
    def annotate(session : MPSH::Session) : Nil
      losses = @annotations.select { |note| note.outcome.degraded? && note.message_index }

      losses.group_by { |note| identity(note) }.each do |key, notes|
        held = session.annotations.count { |note| identity(note) == key }
        notes.skip(held).each { |note| session.annotate(note) }
      end
    end

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

    private def identity(note : MPSH::Annotation)
      {note.outcome, note.provider, note.message_index, note.block_kind}
    end
  end
end
