require "../spec_helper"
require "../fixtures/response_fixtures"
require "../support/loopback"

# The session's register: each content loss once per provider.
#
# `Client` re-maps the whole history on every send, so a block degraded once
# is degraded again on every later turn to the same provider. These pin that
# the register records it once, that it still records two of one kind in one
# message, and that `Client#send` writes it only after an exchange returns.
#
# The `Client` examples serve recorded Anthropic-on-Ollama bodies from a
# `Loopback` server, so they need no transcript of their own and no network.

private alias RF = Liaison::ResponseFixtures

# A Claude turn whose signed thinking an Ollama endpoint cannot replay, so
# sending it there degrades message 1's reasoning block.
private def signed_session : M::Session
  session = M::Session.new("You are terse.")
  session << M::Message.user("What is the tallest mountain?")

  anthropic = Liaison::Protocol::Anthropic::Mapper.new
  session << Liaison::Protocol::Anthropic::Exporter.new(anthropic.calls)
    .export_reply(RF::ANTHROPIC_THINKING)
  session << M::Message.user("And the deepest ocean?")
  session
end

private def ollama_anthropic(url : String = "http://localhost:11434") : Liaison::Provider
  Liaison::Provider.for(Liaison::Server.new("ollama", url), Liaison::ProtocolKind::Anthropic)
end

private def mapped(session : M::Session) : C::Report
  ollama_anthropic.adapter.prepare(session, "gemma4",
    C::Policy::Lenient, C::ReasoningRetention::All, 1024).report
end

private def degraded(report : C::Report, index : Int32, kind : M::BlockKind = M::BlockKind::Image) : Nil
  report.record(M::Outcome::Degraded, "#{kind} as its text fallback", index, kind)
end

private def serving(body : String, status : Int32 = 200, &)
  handler = ->(context : HTTP::Server::Context) {
    context.response.status_code = status
    context.response.print body
    nil
  }
  Loopback.serve(handler) { |url| yield url }
end

describe "the session's register" do
  describe "Report#annotate" do
    it "records a content loss from mapping" do
      session = signed_session
      mapped(session).annotate(session)

      session.annotations.size.should eq 1
      note = session.annotations.first
      note.outcome.should eq M::Outcome::Degraded
      note.provider.should eq "anthropic"
      note.message_index.should eq 1
      note.block_kind.should eq M::BlockKind::Reasoning
    end

    it "records it once however often the same history is sent" do
      session = signed_session
      3.times { mapped(session).annotate(session) }

      session.annotations.size.should eq 1
    end

    it "keeps two losses of one kind in one message as two" do
      session = M::Session.new
      first = C::Report.new("p", C::Policy::Lenient)
      2.times { degraded(first, 2) }

      first.annotate(session)
      first.annotate(session)

      session.annotations.size.should eq 2
    end

    it "adds one more when a later send loses one more" do
      session = M::Session.new
      one = C::Report.new("p", C::Policy::Lenient)
      degraded(one, 2)
      two = C::Report.new("p", C::Policy::Lenient)
      2.times { degraded(two, 2) }

      one.annotate(session)
      two.annotate(session)
      one.annotate(session)

      session.annotations.size.should eq 2
    end

    it "records the same block lost to another provider separately" do
      session = M::Session.new
      [C::Report.new("p", C::Policy::Lenient), C::Report.new("q", C::Policy::Lenient)].each do |report|
        degraded(report, 2)
        report.annotate(session)
      end

      session.annotations.map(&.provider).should eq ["p", "q"]
    end

    it "keeps compensations, sequence changes and request options on the report" do
      session = M::Session.new
      report = C::Report.new("p", C::Policy::Lenient)
      report.record(M::Outcome::Compensated, "image carried after the tool result", 2, M::BlockKind::Image)
      report.record(C::Structural.outcome(C::Structural::Adaptation::DropEmptyMessage),
        "empty message removed to satisfy validation")
      report.record(M::Outcome::Degraded, "reasoning control: clamped")

      report.annotate(session)

      report.annotations.size.should eq 3
      session.annotations.should be_empty
    end

    it "recognises what an archived session already holds" do
      session = signed_session
      mapped(session).annotate(session)

      resumed = M::Archive.read(M::Archive.write(session))
      mapped(resumed).annotate(resumed)

      resumed.annotations.size.should eq 1
    end
  end

  describe "Client#send" do
    it "records the loss of a buffered exchange" do
      serving(Loopback.recorded_body("ollama_anthropic_text")) do |url|
        session = signed_session
        client = Liaison::Client.new(ollama_anthropic(url), C::Policy::Lenient)

        reply, _ = client.send(session, "gemma4")
        session << reply << M::Message.user("And the longest river?")
        client.send(session, "gemma4")

        # Message 1's loss, sent twice, recorded once. The reply's own
        # reasoning is a separate question, so it is not counted here.
        losses = session.annotations.select { |note| note.message_index == 1 }
        losses.size.should eq 1
        losses.first.block_kind.should eq M::BlockKind::Reasoning
      end
    end

    it "records the loss of a streamed exchange" do
      serving(Loopback.recorded_body("ollama_anthropic_stream_text")) do |url|
        session = signed_session
        client = Liaison::Client.new(ollama_anthropic(url), C::Policy::Lenient)

        _, report = client.send(session, "gemma4") { }

        report.streamed?.should be_true
        session.annotations.size.should eq 1
      end
    end

    it "records nothing when the exchange fails" do
      serving(%({"type":"error","error":{"type":"overloaded_error","message":"busy"}}), 529) do |url|
        session = signed_session
        client = Liaison::Client.new(ollama_anthropic(url), C::Policy::Lenient)

        expect_raises(Liaison::OverloadedError) { client.send(session, "gemma4") }

        session.annotations.should be_empty
      end
    end
  end
end
