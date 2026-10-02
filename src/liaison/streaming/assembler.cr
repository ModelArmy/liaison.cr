require "./sse"
require "./event"
require "../mpsh/message"

module Liaison::Streaming
  # Frames in, one `MPSH::Message` out: the per-protocol half of streaming.
  #
  # Never stitch anything whose partial form is invalid. Partial text is
  # valid text, so it is concatenated. A partial tool call cannot be
  # dispatched, so a call still arriving when the stream ended does not
  # appear in the reply. What counts as a whole unit differs by protocol:
  # Responses emits finished items, while Gemini sends only fragments whose
  # text must be joined.
  #
  # `finish` builds the protocol's own `Wire::Response` and passes it to the
  # exporter's `export_reply`, so a streamed reply and a buffered one are the
  # same message by construction. Concrete assemblers also expose that
  # `Wire::Response` for specs.
  abstract class Assembler
    # Takes one frame, yielding zero or more events. A frame with nothing to
    # watch (a keep-alive, a lifecycle marker, a frame type added later)
    # yields none and is not an error.
    abstract def absorb(frame : Sse::Frame, & : Event ->) : Nil

    # Whether a terminal frame arrived. False both for a cut stream and for
    # one the caller stopped; `Client#send` tells them apart.
    abstract def complete? : Bool

    # The reply, whether the stream finished or not.
    abstract def finish : MPSH::Message
  end
end
