require "./profile"
require "./policy"
require "../mpsh/message"

module Liaison::Capability
  # Adaptations to the message sequence rather than to a block, such as
  # merging consecutive same-role messages for Anthropic, each with its own
  # outcome. Merging is not round-trippable, since export cannot know where to
  # cut, so it is declared `Compensated` and the conformance gate expects the
  # divergence.
  module Structural
    extend self

    enum Adaptation
      MergeConsecutiveRoles
      PrependUserPlaceholder
      DropEmptyMessage
      MoveSystemPrompt
      # A compensation carrier held back until every tool result answering one
      # assistant turn has been emitted. Strict servers reject scaffolding
      # interleaved between tool responses.
      DeferCompensationCarrier
      # Export-side. Adjacent `role: "tool"` messages collapse into one MPSH
      # user message, because the wire cannot express whether they arrived as
      # one turn or several. Pairing survives via `call_id`; only the message
      # boundary is lost.
      CollapseAdjacentToolResults
    end

    def outcome(adaptation : Adaptation) : MPSH::Outcome
      case adaptation
      in Adaptation::MoveSystemPrompt            then MPSH::Outcome::Restructured
      in Adaptation::MergeConsecutiveRoles       then MPSH::Outcome::Compensated
      in Adaptation::PrependUserPlaceholder      then MPSH::Outcome::Compensated
      in Adaptation::DropEmptyMessage            then MPSH::Outcome::Degraded
      in Adaptation::DeferCompensationCarrier    then MPSH::Outcome::Compensated
      in Adaptation::CollapseAdjacentToolResults then MPSH::Outcome::Compensated
      end
    end

    # Predicts, from the profile alone, which of `PrependUserPlaceholder`,
    # `MergeConsecutiveRoles` and `MoveSystemPrompt` a history will need. The
    # other adaptations depend on block mapping and appear only in a `Report`.
    def required(messages : Array(MPSH::Message), profile : Profile) : Array(Adaptation)
      needed = [] of Adaptation

      if profile.first_message_must_be_user?
        first = messages.first?
        needed << Adaptation::PrependUserPlaceholder if first && first.role.assistant?
      end

      if profile.alternation_required?
        messages.each_cons(2) do |pair|
          if pair[0].role == pair[1].role
            needed << Adaptation::MergeConsecutiveRoles
            break
          end
        end
      end

      needed << Adaptation::MoveSystemPrompt unless profile.system_placement.in_messages?
      needed
    end
  end
end
