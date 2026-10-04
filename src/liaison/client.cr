require "./provider"

module Liaison
  # Sends one request per `send`: no loop, no tool dispatch, no retries. The
  # turn loop and the session stay the caller's, so the session is portable
  # at every turn:
  #
  # ```
  # loop do
  #   reply, report = client.send(session, "llama3.2")
  #   session << reply
  #
  #   calls = reply.content.select(MPSH::ToolCallBlock).reject(&.server_executed?)
  #   break if calls.empty?
  #
  #   session << MPSH::Message.new(MPSH::Role::User, calls.map { |call| dispatch(call) })
  # end
  # ```
  class Client
    getter provider : Provider
    getter policy : Capability::Policy
    getter retention : Capability::ReasoningRetention

    def initialize(@provider : Provider,
                   @policy : Capability::Policy = Capability::Policy::Compensating,
                   @retention : Capability::ReasoningRetention = Capability::ReasoningRetention::All)
    end

    # Sends the session and returns the reply with its `Report`. `policy` and
    # `retention` override the client's for this call. `max_tokens` defaults
    # per provider; only the Anthropic protocol requires it.
    #
    # The session gains the exchange's content losses as annotations, each
    # once (`Report#annotate`); that is the only change `send` makes to it.
    # The reply is not appended. Everything else the report holds is about
    # this request alone, and a caller that ignores it will not hear of it.
    #
    # Raises `Capability::RefusedError` before sending, a `TransportError` for
    # a failed request, and `Protocol::MalformedResponseError` for an
    # unreadable reply.
    def send(session : MPSH::Session, model : String,
             policy : Capability::Policy? = nil,
             retention : Capability::ReasoningRetention? = nil,
             max_tokens : Int32? = nil,
             options : Options = Options.new) : {MPSH::Message, Capability::Report}
      once(session, model, policy, retention, max_tokens, options)
    end

    # The same turn, streamed: passing a block is the request to stream. The
    # block receives each event and the `Streaming::Turn`, which it can stop.
    #
    # ```
    # reply, report = client.send(session, "gpt-5") do |event, turn|
    #   print event.text if event.is_a?(Liaison::Streaming::TextDelta)
    #   turn.stop if cancelled?
    # end
    # ```
    #
    # The reply is the same `MPSH::Message` a body would give. A stream cut
    # short returns its partial reply with `ending` set to `Stopped` or
    # `Interrupted`; repair it with `MPSH::Repair` before building on it. An
    # adapter that cannot stream sends one body, and `Report#streamed` says so.
    #
    # The block is captured, since it is called inside the block
    # `Server#stream` captures. To the caller it is an ordinary block.
    def send(session : MPSH::Session, model : String,
             policy : Capability::Policy? = nil,
             retention : Capability::ReasoningRetention? = nil,
             max_tokens : Int32? = nil,
             options : Options = Options.new,
             &block : Streaming::Event, Streaming::Turn ->) : {MPSH::Message, Capability::Report}
      adapter = provider.adapter
      streamed = adapter.prepare_stream(session, model,
        policy || @policy,
        retention || @retention,
        max_tokens || provider.default_max_tokens,
        options)

      return once(session, model, policy, retention, max_tokens, options) unless streamed

      turn = Streaming::Turn.new
      assembler = streamed.assembler
      report = streamed.report

      # Annotations come from mapping, before sending, so they open the stream.
      # The parameter is `raised` because `annotation` is a keyword.
      report.annotations.each do |raised|
        block.call(Streaming::AnnotationRaised.new(raised), turn)
      end

      server = provider.server
      server.stream(adapter.stream_path(model), adapter.headers(server.credential), streamed.body,
        ->(body : String) { adapter.error_detail(body) }) do |frame|
        assembler.absorb(frame) { |event| block.call(event, turn) }
        !turn.stopped?
      end

      report.streamed = true
      reply = assembler.finish

      # A stream that ended without its terminal frame returns its partial
      # reply rather than raising; only this layer knows whether the caller
      # stopped it. An in-band error frame still raises, from the assembler.
      unless assembler.complete?
        reply.ending = turn.stopped? ? MPSH::Ending::Stopped : MPSH::Ending::Interrupted
      end

      report.annotate(session)
      {reply, report}
    end

    private def once(session : MPSH::Session, model : String,
                     policy : Capability::Policy?,
                     retention : Capability::ReasoningRetention?,
                     max_tokens : Int32?,
                     options : Options) : {MPSH::Message, Capability::Report}
      exchange = provider.adapter.prepare(session, model,
        policy || @policy,
        retention || @retention,
        max_tokens || provider.default_max_tokens,
        options)

      reply = exchange.read(transmit(model, exchange.body))
      exchange.report.annotate(session)
      {reply, exchange.report}
    end

    # The only method here that touches the network.
    private def transmit(model : String, body : String) : String
      adapter = provider.adapter
      server = provider.server

      server.post(adapter.path(model), adapter.headers(server.credential), body,
        ->(error_body : String) { adapter.error_detail(error_body) })
    end
  end
end
