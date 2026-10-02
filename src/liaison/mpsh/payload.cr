module Liaison::MPSH
  # Binary content, inline or by reference. Both keep `media_type` and
  # `byte_size` separate; the two protocols that want a `data:` URI get one
  # built at map time, since joining is trivial and parsing one back is not.
  abstract class Payload
    getter media_type : String
    getter byte_size : Int64

    def initialize(@media_type : String, @byte_size : Int64)
    end

    abstract def inline? : Bool
  end

  # Base64 text, no `data:` prefix, ever.
  class InlinePayload < Payload
    getter base64 : String

    def initialize(@base64 : String, media_type : String, byte_size : Int64)
      super(media_type, byte_size)
    end

    def inline? : Bool
      true
    end
  end

  # A content-addressed handle into a blob store the caller owns. No blob
  # store can be supplied yet, so mapping one raises `RefusedError`.
  class ReferencePayload < Payload
    getter handle : String

    def initialize(@handle : String, media_type : String, byte_size : Int64)
      super(media_type, byte_size)
    end

    def inline? : Bool
      false
    end
  end
end
