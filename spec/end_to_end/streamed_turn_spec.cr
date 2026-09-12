require "../spec_helper"
require "../support/saved_session"

# A streamed turn, through the archive and out the other side.
#
# **What the CLI's version proved that this does not.** `Display`'s precedence,
# `Progress` drawing only on a tty, and `Output.reply` suppressed on
# `report.streamed?` are all facts about a terminal, and they belong wherever
# the terminal does. What is left is the library's own claim, which is the one
# worth keeping here: a streamed reply is the same `MPSH::Message` as an
# unstreamed one, and stays the same after a trip through a file.
#
# That claim is structural rather than incidental — frames become the protocol's
# own `Wire::Response` and take the existing `export_reply`, so there is one
# export path rather than two. These examples are what would notice if a second
# one ever appeared.
private MODEL = "gemma4:26b-mxfp8"

private STREAMED = "e2e_streamed_turn"
private BUFFERED = "e2e_buffered_turn"

private def ollama : Elelem::Server
  Elelem::Server.new("ollama", "http://localhost:11434")
end

private def client(protocol : Elelem::ProtocolKind) : Elelem::Client
  Elelem::Client.new(Elelem::Provider.for(ollama, protocol))
end

# Reasoning off throughout. Ollama reasons on every endpoint and cannot mint an
# Anthropic thought signature, so the last example here would fail on reasoning
# retention rather than on anything about streaming. `handoff_spec.cr` asserts
# that loss deliberately, where it is the subject.
private def plain : Elelem::Options
  Elelem::Options.new(reasoning: Elelem::Reasoning::Off.new)
end

private def asked : M::Session
  session = M::Session.new("Answer in one short sentence.")
  session << M::Message.user("What is the tallest mountain on Earth?")
  session
end

describe "a streamed turn" do
  it "assembles a reply from the deltas it emitted" do
    # The assembled message is the deltas, concatenated, and nothing else. A
    # reply that gained or lost text between the last frame and `finish` would
    # show up here as a mismatch rather than as a shorter answer nobody
    # questioned.
    Wiretap.intercept(STREAMED) do
      streamed = [] of String
      reply, report = client(Elelem::ProtocolKind::ChatCompletions)
        .send(asked, MODEL, options: plain) do |event, _|
          streamed << event.text if event.is_a?(Elelem::Streaming::TextDelta)
        end

      report.streamed?.should be_true
      streamed.should_not be_empty
      streamed.join.should eq reply.text
    end
  end

  it "produces the message an unstreamed turn produces" do
    # Two transcripts, two requests, one export path. The models' wording will
    # differ between recordings, so what is compared is shape: same role, same
    # ending, same block kinds in the same order. Comparing the text would be
    # asserting something about the model rather than about us.
    Wiretap.intercept(STREAMED) do
      streamed, _ = client(Elelem::ProtocolKind::ChatCompletions).send(asked, MODEL, options: plain) { |_, _| }

      Wiretap.intercept(BUFFERED) do
        buffered, report = client(Elelem::ProtocolKind::ChatCompletions).send(asked, MODEL, options: plain)

        report.streamed?.should be_false
        streamed.role.should eq buffered.role
        streamed.ending.should eq buffered.ending
        streamed.content.map(&.kind).should eq buffered.content.map(&.kind)
        streamed.provenance.try(&.provider).should eq buffered.provenance.try(&.provider)
      end
    end
  end

  it "survives being archived and reloaded" do
    # The half of the CLI's streamed spec that was never about the CLI: a
    # streamed reply is written and read back like any other, and a session
    # resumed tomorrow cannot tell how yesterday's answer arrived.
    SavedSession.in_a_file do |path|
      Wiretap.intercept(STREAMED) do
        session = asked
        reply, _ = client(Elelem::ProtocolKind::ChatCompletions).send(session, MODEL, options: plain) { |_, _| }
        session << reply

        reloaded = SavedSession.round_trip(session, path).messages.last

        reloaded.text.should eq reply.text
        reloaded.ending.should eq reply.ending
        reloaded.content.map(&.kind).should eq reply.content.map(&.kind)
      end
    end
  end

  it "hands a streamed reply to a different protocol" do
    # Streaming and portability are independent, and this is where that stops
    # being an assumption. A reply assembled from Chat Completions frames,
    # archived, and reloaded is sent to the Anthropic endpoint.
    SavedSession.in_a_file do |path|
      Wiretap.intercept(STREAMED) do
        session = asked
        reply, _ = client(Elelem::ProtocolKind::ChatCompletions).send(session, MODEL, options: plain) { |_, _| }
        session << reply

        resumed = SavedSession.round_trip(session, path)
        resumed << M::Message.user("And the second tallest?")

        Wiretap.intercept("e2e_streamed_then_anthropic") do
          second, report = client(Elelem::ProtocolKind::Anthropic).send(resumed, MODEL, options: plain)

          second.content.select(M::TextBlock).should_not be_empty
          report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
        end
      end
    end
  end
end
