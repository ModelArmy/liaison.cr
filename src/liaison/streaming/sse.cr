module Liaison::Streaming
  # Server-sent events framing, and nothing above it. The four protocols
  # share the framing and disagree about what goes in a frame (Anthropic names
  # every frame, Gemini sends bare `data:`, Chat Completions ends with a
  # non-JSON `[DONE]`), so interpreting a frame is the assembler's job.
  module Sse
    # One dispatched event: an optional `event:` name and the joined `data:`
    # payload, as text, since it is not always JSON.
    struct Frame
      getter name : String?
      getter data : String

      def initialize(@data : String, @name : String? = nil)
      end
    end

    # A line, or one frame's joined data, longer than the limit given to
    # `each_frame`.
    class FrameTooLargeError < Exception
    end

    # Reads frames until the stream ends. A line, or one frame's joined data,
    # of more than `max_frame_bytes` raises `FrameTooLargeError`; a line is
    # never read past the limit, so an endless one is not buffered.
    #
    # A trailing partial frame is discarded, as the SSE specification says.
    # That keeps a cut stream detectable: a half-written terminal frame never
    # reaches an assembler, so it cannot pass for a complete one. The cost is
    # that a server omitting the final blank line loses its last event.
    #
    # Handles `\n` and `\r\n` line endings, not a lone `\r`.
    def self.each_frame(io : IO, max_frame_bytes : Int32, & : Frame ->) : Nil
      name = nil.as(String?)
      data = [] of String
      data_bytes = 0

      while line = read_line(io, max_frame_bytes)
        if line.empty?
          yield Frame.new(data.join('\n'), name) unless data.empty?
          name = nil
          data.clear
          data_bytes = 0
          next
        end

        # A comment line; these endpoints send them as keep-alives.
        next if line.starts_with?(':')

        field, _, value = line.partition(":")
        # Exactly one leading space is stripped, per the specification, not
        # all of them, which would eat indentation in the payload.
        value = value[1..] if value.starts_with?(' ')

        # `id` and `retry` serve reconnection, which this client never does,
        # so they are dropped.
        case field
        when "event" then name = value
        when "data"
          data_bytes += value.bytesize + (data.empty? ? 0 : 1)
          raise FrameTooLargeError.new("SSE frame data exceeds #{max_frame_bytes} bytes") if data_bytes > max_frame_bytes
          data << value
        end
      end
    end

    # One line without its terminator. The read stops two bytes past the limit,
    # room for a `\r\n` after a line of exactly the limit.
    private def self.read_line(io : IO, max_frame_bytes : Int32) : String?
      line = io.gets(max_frame_bytes.to_i64 + 2, chomp: true)
      if line && line.bytesize > max_frame_bytes
        raise FrameTooLargeError.new("SSE line exceeds #{max_frame_bytes} bytes")
      end
      line
    end
  end
end
