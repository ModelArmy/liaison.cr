require "./adapter"
require "../protocol/gemini/mapper"
require "../protocol/gemini/export"
require "../protocol/gemini/stream"

module Liaison
  class GeminiAdapter < Adapter
    def profile : Capability::Profile
      Protocol::Gemini::PROFILE
    end

    # The only protocol that puts the model in the path rather than the body,
    # which is why `path` takes it at all.
    def path(model : String) : String
      "/v1beta/models/#{URI.encode_path_segment(model)}:generateContent"
    end

    def headers(credential : String?) : HTTP::Headers
      headers = HTTP::Headers{"content-type" => "application/json"}
      # Header form rather than the `?key=` query parameter: a credential in a
      # URL ends up in logs and proxy traces.
      credential.try { |value| headers["x-goog-api-key"] = value }
      headers
    end

    # The envelope the other protocols use. Gemini may also return a bare
    # array of them, which `nested_error` does not handle.
    def error_detail(body : String) : String?
      nested_error(body)
    end

    # Streaming is a different method on the URL here, not a flag in the body.
    # `alt=sse` is required: without it the endpoint streams a chunked JSON
    # array instead of server-sent events.
    def stream_path(model : String) : String
      "/v1beta/models/#{URI.encode_path_segment(model)}:streamGenerateContent?alt=sse"
    end

    def prepare(session : MPSH::Session, model : String, policy : Capability::Policy,
                retention : Capability::ReasoningRetention, max_tokens : Int32,
                options : Options = Options.new) : Exchange
      request, report, exporter = build(session, model, policy, retention, max_tokens, options)

      Exchange.new(request.to_json, report, ->(body : String) { exporter.export_reply(body) })
    end

    # The body is the same as unstreamed; only `stream_path` differs.
    def prepare_stream(session : MPSH::Session, model : String, policy : Capability::Policy,
                       retention : Capability::ReasoningRetention, max_tokens : Int32,
                       options : Options = Options.new) : StreamExchange?
      request, report, exporter = build(session, model, policy, retention, max_tokens, options)

      StreamExchange.new(request.to_json, report, Protocol::Gemini::Assembler.new(exporter))
    end

    private def build(session : MPSH::Session, model : String, policy : Capability::Policy,
                      retention : Capability::ReasoningRetention, max_tokens : Int32,
                      options : Options)
      mapper = Protocol::Gemini::Mapper.new(narrowed(model))
      request, report = mapper.map(session, model, policy, retention, options)
      {request, report, Protocol::Gemini::Exporter.new(mapper.calls)}
    end
  end
end
