module Liaison
  # What the caller asks of the model's reasoning on one request. A closed
  # union, so a mapper's `case ... in` is exhaustive and a request cannot
  # carry a rung and a budget at once, which every protocol rejects.
  #
  # Request options, never session content (`docs/MPSH_SPECIFICATION.md`,
  # §3a).
  module Reasoning
    # Named rungs, taken from the vendors' own ladders rather than an invented
    # scale: Anthropic and OpenAI spell these five, though which ones a model
    # accepts varies. `none` is excluded because `Off` means it; `minimal`
    # because only one family has it, where `Low` is its neighbour.
    enum Effort
      Low
      Medium
      High
      XHigh
      Max

      # Lowercase, as both OpenAI protocols and Anthropic spell it. Gemini's
      # levels are in `Protocol::Gemini::REASONING_LEVELS`.
      def wire_name : String
        case self
        in Effort::Low    then "low"
        in Effort::Medium then "medium"
        in Effort::High   then "high"
        in Effort::XHigh  then "xhigh"
        in Effort::Max    then "max"
        end
      end
    end

    # An exact token budget. Raises `ArgumentError` unless positive.
    struct Budget
      getter tokens : Int32

      def initialize(@tokens : Int32)
        raise ArgumentError.new("reasoning budget must be positive") unless @tokens > 0
      end

      # The rung a budget becomes for a protocol that takes only rungs. One
      # table for every protocol, and ours, since no vendor publishes
      # budget-to-rung; `ReasoningControl` reports the conversion as
      # `Degraded`.
      def to_effort : Effort
        case tokens
        when .< 2_048  then Effort::Low
        when .< 8_192  then Effort::Medium
        when .< 24_576 then Effort::High
        when .< 65_536 then Effort::XHigh
        else                Effort::Max
        end
      end
    end

    # Asks for no thinking. Not the same as no request, which leaves the
    # provider's default.
    struct Off
    end

    alias Request = Effort | Budget | Off

    # Whether a reply's reasoning should come back as text, where an API would
    # otherwise withhold it. `Summarized`, the default, asks for it: a session
    # can only be resumed with what was captured, and reasoning text is all of
    # it that crosses vendors (`DEVELOPMENT.md`, *What this shard is for*). The
    # text is a summary, never the raw reasoning. `Omitted` declines it, which
    # shortens the wait for the first streamed token at the cost of fidelity
    # when the session is continued, on another vendor most of all.
    enum Text
      Summarized
      Omitted
    end
  end
end
