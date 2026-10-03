require "../mpsh/annotation"
require "../mpsh/meta"

module Liaison::Streaming
  # What a caller may watch while a reply is generated. Presentation only:
  # the reply is authoritative, and a caller assembling events into a reply
  # has rewritten the exporter, worse.
  #
  # A closed union, like `MPSH::Block`, so `case event; in TextDelta` is
  # checked for exhaustiveness and a new variant breaks every consumer until
  # it is handled.
  #
  # There is no terminal event. Whether the model finished or wants a tool is
  # read off the reply.

  # A fragment of the assistant's answer.
  struct TextDelta
    getter text : String

    def initialize(@text : String)
    end
  end

  # A fragment of the model's reasoning. Emitted under every
  # `Capability::ReasoningRetention`, including `None`: retention applies to
  # replay on the next request, and the reply still carries its reasoning.
  # Whether to display it is the caller's decision.
  struct ReasoningDelta
    getter text : String

    def initialize(@text : String)
    end
  end

  # The model has begun a tool call. Carries the name only, so a caller can
  # show that a pause is a tool call, but cannot dispatch or assemble one from
  # events; calls are read off the reply.
  struct ToolCallStarted
    getter name : String

    def initialize(@name : String)
    end
  end

  # A fidelity annotation, delivered live. Mapping is complete before the
  # request is sent, so these all arrive at the head of the stream.
  struct AnnotationRaised
    getter annotation : MPSH::Annotation

    def initialize(@annotation : MPSH::Annotation)
    end
  end

  # Something a provider streams that has no canonical equivalent, namespaced
  # by vendor as `provider_metadata` is, so a consumer reads only the vendor
  # it understands.
  struct ProviderDelta
    getter vendor : String
    getter data : MPSH::Object

    def initialize(@vendor : String, @data : MPSH::Object)
    end
  end

  alias Event = TextDelta |
                ReasoningDelta |
                ToolCallStarted |
                AnnotationRaised |
                ProviderDelta
end
