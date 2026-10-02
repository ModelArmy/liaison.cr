require "./profile"
require "../reasoning"
require "../mpsh/annotation"

module Liaison::Capability
  # Decides how a reasoning request is rendered for a protocol's
  # `ReasoningUnit`, and at what fidelity. Beside `Structural` rather than in
  # `Resolver`, which answers questions about blocks. Derived from the
  # `Profile`, so the outcome a caller is told and the branch a mapper takes
  # agree.
  module ReasoningControl
    extend self

    # What the mapper should put on the wire. The *values* are the protocol's
    # own business; this only decides the shape.
    enum Rendering
      AsEffort # a named rung, in the protocol's spelling
      AsBudget # a token count, clamped by the protocol's own rules
      Disable  # ask for no thinking at all
      Drop     # emit nothing; the request loses what the caller asked for
    end

    # The full matrix. A rung rendered as a budget is `Restructured`: the
    # rung's meaning survives, through a budget table each protocol draws from
    # its vendor's guidance. A budget rendered as a rung is `Degraded`: the
    # number is lost, and a rung is a behavioural signal rather than a cap.
    def resolve(request : Reasoning::Request, unit : ReasoningUnit) : {Rendering, MPSH::Outcome}
      case unit
      in ReasoningUnit::None
        # The protocol has no control at all. Nothing to send, and the caller
        # asked for something they will not get.
        {Rendering::Drop, MPSH::Outcome::Degraded}
      in ReasoningUnit::Either
        # `Either`, unresolved. `Catalog.narrow` always resolves it, so this is
        # reached only by a mapper built from an un-narrowed profile. Guessing
        # would risk a 400; dropping is a recorded loss.
        {Rendering::Drop, MPSH::Outcome::Degraded}
      in ReasoningUnit::Effort
        case request
        in Reasoning::Effort then {Rendering::AsEffort, MPSH::Outcome::Exact}
        in Reasoning::Budget then {Rendering::AsEffort, MPSH::Outcome::Degraded}
        in Reasoning::Off    then {Rendering::Disable, MPSH::Outcome::Exact}
        end
      in ReasoningUnit::Budget
        case request
        in Reasoning::Effort then {Rendering::AsBudget, MPSH::Outcome::Restructured}
        in Reasoning::Budget then {Rendering::AsBudget, MPSH::Outcome::Exact}
        in Reasoning::Off    then {Rendering::Disable, MPSH::Outcome::Exact}
        end
      end
    end

    # Wording for the annotation, kept here so four mappers describe the same
    # event the same way.
    def detail(request : Reasoning::Request, rendering : Rendering,
               unit : ReasoningUnit) : String
      asked = case request
              in Reasoning::Effort then "effort #{request.wire_name}"
              in Reasoning::Budget then "budget #{request.tokens}"
              in Reasoning::Off    then "reasoning off"
              end

      case rendering
      in Rendering::Drop     then "reasoning control: #{asked} not expressible (#{unit})"
      in Rendering::AsEffort then "reasoning control: #{asked} sent as a named rung"
      in Rendering::AsBudget then "reasoning control: #{asked} sent as a token budget"
      in Rendering::Disable  then "reasoning control: #{asked}"
      end
    end
  end
end
