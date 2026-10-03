module Liaison::Protocol
  # A response body that cannot be read as this protocol's shape: truncated,
  # an error object where a reply was expected, or another protocol's shape.
  # Not a `Capability::RefusedError`, which is a fidelity outcome; this is a
  # transport fault and stays out of the fidelity record.
  #
  # Readers are tolerant: unknown fields are ignored, and only a body missing
  # its required shape raises.
  class MalformedResponseError < Exception
    getter provider : String

    def initialize(@provider : String, detail : String)
      super("#{@provider}: #{detail}")
    end
  end
end

module Liaison::Protocol
  class MalformedResponseError < Exception
    getter provider : String

    def initialize(@provider : String, detail : String)
      super("#{@provider}: #{detail}")
    end
  end

  # A streamed generation that failed after its 200: an in-band error frame.
  # Not a `TransportError`, whose `status` and `transient?` would have nothing
  # true to report once the status was committed.
  #
  # `source` names the protocol when an assembler raises it, since assemblers
  # know no server. `type` is the vendor's own name for the error, verbatim, or
  # `nil` when the frame carries none.
  class StreamError < Exception
    getter source : String
    getter type : String?

    def initialize(@source : String, detail : String, @type : String? = nil)
      super(@type ? "#{@source}: #{@type} — #{detail}" : "#{@source}: #{detail}")
    end
  end
end
