require "../spec_helper"
require "../support/saved_session"

# The product claim, end to end: answer on one protocol, save to a file, reload
# from that file, continue on another.
#
# **What this covers that nothing else does.** `spec/conformance/handoff_spec.cr`
# proves a reply maps into a foreign request, offline. `spec/live/ollama_spec.cr`
# proves a real endpoint accepts one. Both hold the session in memory for the
# whole run, and `spec/mpsh/archive_spec.cr` round-trips through a `String`.
# Nothing until now has put a session on a disk, picked it back up in a fresh
# object, and sent it — which is the thing a user actually does between Tuesday
# and Wednesday.
#
# **Why Ollama and why that is not enough.** One deployment serves Chat
# Completions, Responses and Anthropic, so a cross-protocol handoff costs
# nothing and needs no key. `docs/servers/OLLAMA.md` is the reason that is not
# the whole story: this server accepts more than the endpoints it imitates, so a
# green run here proves the round trip is *consistent*, not that a vendor would
# take it. The vendor half lives in `spec/live/`, one protocol at a time.
private MODEL = "gemma4:26b-mxfp8"

private SAVED_CHAT_TO_ANTHROPIC = "e2e_saved_chat_to_anthropic"
private SAVED_THREE_PROTOCOLS   = "e2e_saved_three_protocols"
private SAVED_WITH_REASONING    = "e2e_saved_with_reasoning"

private def ollama : Liaison::Server
  Liaison::Server.new("ollama", "http://localhost:11434")
end

private def client(protocol : Liaison::ProtocolKind,
                   policy : Liaison::Capability::Policy = Liaison::Capability::Policy::Compensating) : Liaison::Client
  Liaison::Client.new(Liaison::Provider.for(ollama, protocol), policy)
end

# Reasoning off, on every leg that hands off.
#
# Not a convenience. Ollama emits reasoning from all three of its endpoints and
# cannot mint an Anthropic thought signature, so a reasoning block carried into
# an Anthropic request degrades — correctly, and `Compensating` refuses it. That
# is a fact about reasoning retention, not about whether a session survives a
# file, and a handoff spec that tripped over it would be testing two things and
# failing for the wrong one. The lossy case gets its own example at the end,
# where it is the subject rather than the weather.
private def plain : Liaison::Options
  Liaison::Options.new(reasoning: Liaison::Reasoning::Off.new)
end

private def opened : M::Session
  session = M::Session.new("Answer in one short sentence.")
  session << M::Message.user("What is the tallest mountain on Earth?")
  session
end

describe "a session that survives a file" do
  it "answers on Chat Completions and continues on Anthropic" do
    SavedSession.in_a_file do |path|
      Wiretap.intercept(SAVED_CHAT_TO_ANTHROPIC) do
        session = opened
        first, _ = client(Liaison::ProtocolKind::ChatCompletions).send(session, MODEL, options: plain)
        session << first

        # The hop. Everything after this reads from disk, and the in-memory
        # session is deliberately not reused.
        resumed = SavedSession.round_trip(session, path)
        resumed.messages.size.should eq 2
        resumed.system_prompt.should eq "Answer in one short sentence."

        resumed << M::Message.user("And the second tallest?")
        second, report = client(Liaison::ProtocolKind::Anthropic).send(resumed, MODEL, options: plain)

        second.content.select(M::TextBlock).should_not be_empty
        report.annotations.map(&.outcome).should_not contain M::Outcome::Refused
      end
    end
  end

  it "reloads a reply identical to the one that was saved" do
    # The archive is where a portable session stops being an object and starts
    # being a format, so this asserts the fields `Conformance.compare` cannot
    # see: `ending` is dropped by every wire, and `provenance` is a historical
    # record no protocol carries. `DEVELOPMENT.md`'s *The conformance gate* is
    # the argument for checking them here rather than assuming the gate did.
    SavedSession.in_a_file do |path|
      Wiretap.intercept(SAVED_CHAT_TO_ANTHROPIC) do
        session = opened
        first, _ = client(Liaison::ProtocolKind::ChatCompletions).send(session, MODEL, options: plain)
        session << first

        reloaded = SavedSession.round_trip(session, path).messages.last

        reloaded.role.should eq first.role
        reloaded.text.should eq first.text
        reloaded.ending.should eq first.ending
        reloaded.provenance.try(&.provider).should eq first.provenance.try(&.provider)
        reloaded.provenance.try(&.model).should eq first.provenance.try(&.model)
      end
    end
  end

  it "carries one conversation across all three protocols, saving between each" do
    # The claim at its widest. Each leg reloads from the file the previous leg
    # wrote, so a field that survives mapping but not archiving fails here and
    # nowhere else.
    SavedSession.in_a_file do |path|
      Wiretap.intercept(SAVED_THREE_PROTOCOLS) do
        session = opened

        [Liaison::ProtocolKind::ChatCompletions,
         Liaison::ProtocolKind::Responses,
         Liaison::ProtocolKind::Anthropic].each_with_index do |protocol, index|
          session << M::Message.user("Name another one.") if index > 0

          reply, report = client(protocol).send(session, MODEL, options: plain)
          report.annotations.map(&.outcome).should_not contain M::Outcome::Refused

          session << reply
          session = SavedSession.round_trip(session, path)
        end

        session.messages.size.should eq 6
        session.messages.count { |message| message.role.assistant? }.should eq 3
      end
    end
  end

  it "does not let the provider that answered influence what is sent next" do
    # Provenance is inert by design: a session that acquired a *home* from the
    # provider that answered would not be portable. `handoff_spec.cr` asserts
    # this against two mappers in memory; here the record has been through a
    # file, which is where an inert field is most likely to acquire meaning by
    # accident.
    SavedSession.in_a_file do |path|
      Wiretap.intercept(SAVED_CHAT_TO_ANTHROPIC) do
        session = opened
        first, _ = client(Liaison::ProtocolKind::ChatCompletions).send(session, MODEL, options: plain)
        session << first

        reloaded = SavedSession.round_trip(session, path)
        reloaded.messages.last.provenance.should_not be_nil

        naive = opened
        naive << M::Message.new(M::Role::Assistant,
          [M::TextBlock.new(reloaded.messages.last.text).as(M::Block)])

        theirs, _ = Liaison::Protocol::Anthropic::Mapper.new.map(reloaded, MODEL)
        ours, _ = Liaison::Protocol::Anthropic::Mapper.new.map(naive, MODEL)

        theirs.to_json.should eq ours.to_json
      end
    end
  end

  it "reports the loss when reasoning crosses into a protocol that cannot carry it" do
    # The case the four examples above switch off, asserted here on purpose.
    # Ollama reasons on every endpoint and cannot mint an Anthropic thought
    # signature, so a reasoning block reloaded from a file and sent to the
    # Anthropic endpoint is degraded rather than carried.
    #
    # `Compensating` refuses this, which is why the other examples do not meet
    # it. `Lenient` accepts it and records each occurrence — and the recording
    # is the point: a silent drop and a reported one are different products.
    SavedSession.in_a_file do |path|
      Wiretap.intercept(SAVED_WITH_REASONING) do
        session = opened
        first, _ = client(Liaison::ProtocolKind::ChatCompletions).send(session, MODEL)
        first.content.select(M::ReasoningBlock).should_not be_empty
        session << first

        resumed = SavedSession.round_trip(session, path)
        resumed.messages.last.content.select(M::ReasoningBlock).should_not be_empty
        resumed << M::Message.user("And the second tallest?")

        strict = client(Liaison::ProtocolKind::Anthropic)
        expect_raises(Liaison::Capability::RefusedError) do
          strict.send(resumed, MODEL)
        end

        lenient = client(Liaison::ProtocolKind::Anthropic, Liaison::Capability::Policy::Lenient)
        _, report = lenient.send(resumed, MODEL)
        report.annotations.map(&.outcome).should contain M::Outcome::Degraded
      end
    end
  end
end
