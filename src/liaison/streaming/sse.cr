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

    # Reads frames until the stream ends.
    #
    # A trailing partial frame is discarded, as the SSE specification says.
    # That keeps a cut stream detectable: a half-written terminal frame never
    # reaches an assembler, so it cannot pass for a complete one. The cost is
    # that a server omitting the final blank line loses its last event.
    #
    # Handles `\n` and `\r\n` line endings, not a lone `\r`.
    def self.each_frame(io : IO, & : Frame ->) : Nil
      name = nil.as(String?)
      data = [] of String

      while line = io.gets(chomp: true)
        if line.empty?
          yield Frame.new(data.join('\n'), name) unless data.empty?
          name = nil
          data.clear
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
        when "data"  then data << value
        end
      end
    end
  end
end
