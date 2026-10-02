require "./profile"

module Liaison::Capability
  # Per-model narrowing of a protocol's `Profile`, for capabilities that
  # differ between models on one protocol: the reasoning unit, and whether tool
  # calls must carry a signature. Each axis only narrows (resolving `Either`,
  # or adding a condition) and sets one `Profile` field, leaving the rest to
  # `Resolver`.
  #
  # Entries are exact model strings, matched after downcasing, never patterns.
  # An unlisted name gets the default. Only the reasoning unit can be
  # overridden, through `Provider`'s `reasoning_unit:`, which a deployment
  # name carrying no model identity (Azure's, a gateway's) needs.
  #
  # Both defaults are optimistic, for different reasons. Read *Three
  # identities, kept apart* in `DEVELOPMENT.md` before adding an axis.
  module Catalog
    extend self

    # Models that take a thinking budget and no named rung: Claude 3.7 Sonnet,
    # the Claude 4 models up to Sonnet and Haiku 4.5, and the Gemini 2.5
    # series. Claude Opus 4.5 takes both and is left to the default. A list of
    # the past, so it only shrinks; confirm against current vendor docs.
    BUDGET_ONLY = Set{
      "claude-3-7-sonnet",
      "claude-3-7-sonnet-latest",
      "claude-3-7-sonnet-20250219",
      "claude-sonnet-4",
      "claude-sonnet-4-0",
      "claude-sonnet-4-20250514",
      "claude-sonnet-4-5",
      "claude-sonnet-4-5-20250929",
      "claude-opus-4",
      "claude-opus-4-0",
      "claude-opus-4-20250514",
      "claude-opus-4-1",
      "claude-opus-4-1-20250805",
      "claude-haiku-4-5",
      "claude-haiku-4-5-20251001",
      "gemini-2.5-pro",
      "gemini-2.5-flash",
      "gemini-2.5-flash-lite",
      "gemini-2.5-flash-preview",
      "gemini-2.5-pro-preview",
    }

    # Models whose tool calls must carry their own `thoughtSignature`: the
    # Gemini 3 series, where an unsigned call is a 400 (`Function call is
    # missing a thought_signature in functionCall parts`). The 2.5 series has
    # no such requirement.
    #
    # Only spellings this repository has used, or seen named by the API, go
    # here: a wrong entry silently degrades every tool call sent to that model,
    # while a missing one is a 400 naming the field, fixed by adding a line.
    SIGNED_TOOL_CALLS = Set{
      # Confirmed by a live 400 in this repository.
      "gemini-3.5-flash",
      # Same generation, in use here for the reasoning-tier specs.
      "gemini-3.1-pro-preview",
      # Named by the API's own 404 as the current replacements for the
      # retired 2.5 models.
      "gemini-3.5-flash-lite",
      "gemini-3.6-flash",
    }

    # The unit this model needs, or `nil` where the catalog has no opinion,
    # leaving the default.
    def reasoning_unit?(model : String) : ReasoningUnit?
      BUDGET_ONLY.includes?(model.downcase) ? ReasoningUnit::Budget : nil
    end

    # Whether this model requires signed tool calls.
    def tool_call_signature_required?(model : String) : Bool
      SIGNED_TOOL_CALLS.includes?(model.downcase)
    end

    # Narrows a profile for one model, one independent axis at a time. A no-op
    # on both OpenAI protocols, which have nothing to narrow.
    def narrow(profile : Profile, model : String) : Profile
      if profile.reasoning_unit.either?
        profile = profile.with_reasoning_unit(reasoning_unit?(model) || ReasoningUnit::Effort)
      end

      if tool_call_signature_required?(model) && !profile.tool_call_signature_required?
        profile = profile.with_tool_call_signature_required(true)
      end

      profile
    end
  end
end
