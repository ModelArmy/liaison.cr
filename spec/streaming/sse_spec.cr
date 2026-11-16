require "../spec_helper"

# SSE framing, tested away from any protocol.
#
# This is the one part of streaming all four protocols genuinely share, so it
# is the one part where a bug is four bugs. It is also the part most easily
# tested wrongly: a spec that fed it well-formed frames from a real transcript
# would pass without touching a single case that actually bites — the
# keep-alive comment, the payload that is not JSON, the body that stops
# mid-frame.
#
# Frames are written out as literal strings rather than built, because the
# thing under test *is* the byte format. A helper that assembled well-formed
# input would be a second implementation of the parser, agreeing with the first
# by construction.

private def frames(raw : String) : Array(S::Sse::Frame)
  collected = [] of S::Sse::Frame
  S::Sse.each_frame(IO::Memory.new(raw), 1_000_000) { |frame| collected << frame }
  collected
end

private def frames_within(raw : String, limit : Int32) : Array(S::Sse::Frame)
  collected = [] of S::Sse::Frame
  S::Sse.each_frame(IO::Memory.new(raw), limit) { |frame| collected << frame }
  collected
end

describe Liaison::Streaming::Sse do
  describe ".each_frame" do
    describe "with a frame limit" do
      it "accepts a line of exactly the limit, with either line ending" do
        {"data: 12345\n\n", "data: 12345\r\n\r\n"}.each do |raw|
          frames_within(raw, 11).map(&.data).should eq(["12345"])
        end
      end

      it "raises for a line over the limit" do
        expect_raises(S::Sse::FrameTooLargeError, /line/) { frames_within("data: 123456\n\n", 11) }
      end

      it "raises for a comment line over the limit" do
        expect_raises(S::Sse::FrameTooLargeError, /line/) { frames_within(": #{"x" * 20}\n\n", 11) }
      end

      it "raises for joined data over the limit, though every line is within it" do
        expect_raises(S::Sse::FrameTooLargeError, /frame data/) do
          frames_within("data: 123456\ndata: 123456\n\n", 12)
        end
      end

      it "counts each frame's data on its own" do
        frames_within("data: 123456\n\ndata: 123456\n\n", 12).size.should eq(2)
      end

      it "does not read an endless line past the limit" do
        io = IO::Memory.new("data: " + "x" * 100_000)
        expect_raises(S::Sse::FrameTooLargeError) { S::Sse.each_frame(io, 100) { } }
        io.pos.should be < 1000
      end
    end

    it "reads a lone data frame" do
      read = frames("data: hello\n\n")

      read.size.should eq(1)
      read.first.data.should eq("hello")
      read.first.name.should be_nil
    end

    it "carries the event name when the stream gives one" do
      read = frames("event: response.output_text.delta\ndata: hi\n\n")

      read.first.name.should eq("response.output_text.delta")
      read.first.data.should eq("hi")
    end

    it "joins several data lines with newlines" do
      read = frames("data: first\ndata: second\ndata: third\n\n")

      read.size.should eq(1)
      read.first.data.should eq("first\nsecond\nthird")
    end

    it "reads frames in order" do
      read = frames("data: one\n\ndata: two\n\ndata: three\n\n")

      read.map(&.data).should eq(["one", "two", "three"])
    end

    it "resets the event name between frames" do
      read = frames("event: named\ndata: one\n\ndata: two\n\n")

      read[0].name.should eq("named")
      read[1].name.should be_nil
    end
  end

  describe "field parsing" do
    it "strips exactly one space after the colon" do
      # Two spaces in, one space out. `lstrip` would eat both and take
      # indentation that belongs to the payload with it.
      read = frames("data:  padded\n\n")

      read.first.data.should eq(" padded")
    end

    it "accepts a field with no space after the colon" do
      read = frames("data:tight\n\n")

      read.first.data.should eq("tight")
    end

    it "treats a bare field name as an empty value" do
      read = frames("data\n\n")

      read.size.should eq(1)
      read.first.data.should eq("")
    end

    it "keeps an explicitly empty data line" do
      read = frames("data:\n\n")

      read.size.should eq(1)
      read.first.data.should eq("")
    end

    it "ignores comment lines" do
      # Every one of these endpoints uses comments as keep-alives, so this is
      # the ordinary case during a slow generation rather than an oddity.
      read = frames(": keep-alive\ndata: hello\n: another\n\n")

      read.size.should eq(1)
      read.first.data.should eq("hello")
    end

    it "ignores fields it has no use for" do
      # `id` and `retry` serve reconnection, which is out of scope. They are
      # dropped rather than stored somewhere nothing reads.
      read = frames("id: 42\nretry: 3000\ndata: hello\n\n")

      read.size.should eq(1)
      read.first.data.should eq("hello")
    end

    it "handles CRLF line endings" do
      read = frames("event: named\r\ndata: hello\r\n\r\n")

      read.size.should eq(1)
      read.first.name.should eq("named")
      read.first.data.should eq("hello")
    end
  end

  describe "what it refuses to invent" do
    it "does not dispatch a frame that carried no data lines" do
      # A name with nothing under it is not an event. Dispatching it would hand
      # an assembler a frame whose payload it must then guard against.
      frames("event: ping\n\n").should be_empty
    end

    it "yields nothing for an empty stream" do
      frames("").should be_empty
    end

    it "yields nothing for a stream of only keep-alives" do
      frames(": ping\n\n: ping\n\n").should be_empty
    end

    it "passes a payload that is not JSON through untouched" do
      # Chat Completions ends with this, and it is the reason `data` is a
      # String. A parser in the shared layer would have to fail here or
      # special-case one protocol.
      read = frames("data: [DONE]\n\n")

      read.first.data.should eq("[DONE]")
    end

    it "does not parse the payload it carries" do
      read = frames(%(data: {"type":"delta","text":"a: b"}\n\n))

      read.first.data.should eq(%({"type":"delta","text":"a: b"}))
    end
  end

  describe "a stream that stops early" do
    # The load-bearing behaviour. Discarding a pending frame is what makes a
    # cut stream *detectable*: the terminal frame never reaches an assembler,
    # so `SCOPE.md`'s class-3 interruption shows up as the absence it is. A
    # parser that dispatched the fragment would let a half-written terminal
    # frame pass for a complete one.

    it "discards a trailing frame that was never dispatched" do
      read = frames("data: complete\n\ndata: pending\n")

      read.map(&.data).should eq(["complete"])
    end

    it "discards a frame cut off mid-line" do
      read = frames(%(data: complete\n\ndata: {"partial":))

      read.map(&.data).should eq(["complete"])
    end

    it "discards a frame cut off between its data lines" do
      read = frames("data: complete\n\ndata: first\ndata: second\n")

      read.map(&.data).should eq(["complete"])
    end

    it "keeps everything that was dispatched before the cut" do
      read = frames("data: one\n\ndata: two\n\ndata: thr")

      read.map(&.data).should eq(["one", "two"])
    end
  end
end
