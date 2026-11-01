require "http/headers"
require "../options"
require "../capability/catalog"
require "../streaming/assembler"

module Liaison
  # Which protocol a provider speaks. Not named `Protocol`, which is the
  # namespace holding the four implementations.
  enum ProtocolKind
    ChatCompletions
    Responses
    Anthropic
    Gemini
  end

  # How one protocol is spoken over HTTP: where to post, which headers, how to
  # prepare a request and read its reply. `Client` knows no protocol; a new
  # one adds an adapter and touches no client code.
  abstract class Adapter
    # The vendor this deployment honours opaque data for. See `narrowed`.
    getter vendor : String?

    # The reasoning unit this deployment wants, overriding the catalog; see
    # `narrowed(model)`.
    getter reasoning_unit : Capability::ReasoningUnit?

    def initialize(@vendor : String? = nil,
                   @reasoning_unit : Capability::ReasoningUnit? = nil)
    end

    # A prepared request: its body, its report, and the reader for its reply.
    # The reader closes over an exporter built from the mapper's own
    # `CallIdTable`, so the two always share it.
    struct Exchange
      getter body : String
      getter report : Capability::Report

      def initialize(@body : String, @report : Capability::Report,
                     @reader : Proc(String, MPSH::Message))
      end

      def read(response_body : String) : MPSH::Message
        @reader.call(response_body)
      end
    end

    # The streamed counterpart of `Exchange`, with an assembler in place of a
    # reader.
    struct StreamExchange
      getter body : String
      getter report : Capability::Report
      getter assembler : Streaming::Assembler

      def initialize(@body : String, @report : Capability::Report,
                     @assembler : Streaming::Assembler)
      end
    end

    abstract def profile : Capability::Profile
    abstract def path(model : String) : String

    # Where a streamed request goes. The same as `path`, except on Gemini,
    # where streaming is a different method on the URL.
    def stream_path(model : String) : String
      path(model)
    end

    abstract def prepare(session : MPSH::Session, model : String,
                         policy : Capability::Policy,
                         retention : Capability::ReasoningRetention,
                         max_tokens : Int32,
                         options : Options) : Exchange

    # `prepare`, asking for a stream, or `nil` if this adapter cannot stream;
    # `Client` then sends one body and `Report#streamed` stays false.
    def prepare_stream(session : MPSH::Session, model : String,
                       policy : Capability::Policy,
                       retention : Capability::ReasoningRetention,
                       max_tokens : Int32,
                       options : Options = Options.new) : StreamExchange?
      nil
    end

    # Protocol-specific auth and versioning. The credential is the server's;
    # how it is spelled on the wire is the protocol's.
    def headers(credential : String?) : HTTP::Headers
      HTTP::Headers{"content-type" => "application/json"}
    end

    # The provider's own message from a non-2xx body, or `nil`. Best-effort,
    # and meant never to raise, so a strange error body cannot replace the
    # original failure.
    def error_detail(body : String) : String?
      nil
    end

    # The protocol's profile, narrowed for this deployment's vendor. When
    # `vendor` differs from the profile's `metadata_key`, the key is
    # reassigned, so `Resolver#own?` stops recognising the vendor's opaque
    # data and it degrades. Narrowing only: a deployment may honour less than
    # its protocol (Ollama's Anthropic endpoint ignores thinking signatures),
    # never more.
    def narrowed : Capability::Profile
      key = @vendor
      return profile unless key && key != profile.metadata_key
      profile.with_metadata_key(key)
    end

    # `narrowed`, then narrowed for one model by `Catalog.narrow`. An explicit
    # `reasoning_unit` resolves an `Either` unit first, so it takes the place
    # of the catalog's unit and leaves its other axes to apply; on a protocol
    # with a fixed unit it is ignored.
    def narrowed(model : String) : Capability::Profile
      base = narrowed
      if (unit = @reasoning_unit) && base.reasoning_unit.either?
        base = base.with_reasoning_unit(unit)
      end
      Capability::Catalog.narrow(base, model)
    end

    private def bearer(credential : String?) : HTTP::Headers
      headers = HTTP::Headers{"content-type" => "application/json"}
      credential.try { |value| headers["authorization"] = "Bearer #{value}" }
      headers
    end

    # Azure's auth: the credential as a plain `api-key` header, not a bearer
    # token.
    private def api_key(credential : String?) : HTTP::Headers
      headers = HTTP::Headers{"content-type" => "application/json"}
      credential.try { |value| headers["api-key"] = value }
      headers
    end

    # Reads `{"error": {"message": ...}}`, the envelope both OpenAI protocols,
    # Anthropic and Gemini use. Returns `nil` for unparseable JSON and for
    # JSON of any other shape.
    private def nested_error(body : String) : String?
      JSON.parse(body).as_h?
        .try(&.["error"]?).try(&.as_h?)
        .try(&.["message"]?).try(&.as_s?)
    rescue JSON::ParseException
      nil
    end
  end
end
