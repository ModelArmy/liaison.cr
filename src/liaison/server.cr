require "http/client"
require "uri"
require "./streaming/sse"

module Liaison
  # A live call that failed at the transport, carrying the HTTP status.
  # Separate from `Protocol::MalformedResponseError`, a body that arrived and
  # could not be read: a 429 is worth waiting on, a garbled reply is not.
  class TransportError < Exception
    getter status : Int32
    getter server : String
    # Whatever the adapter salvaged from the error body, if anything.
    getter detail : String?

    def initialize(@server : String, @status : Int32, @detail : String? = nil)
      super(@detail ? "#{@server}: HTTP #{@status} — #{@detail}" : "#{@server}: HTTP #{@status}")
    end

    # Worth trying again later; the request itself was not the problem.
    def transient? : Bool
      @status == 429 || @status >= 500
    end
  end

  class AuthError < TransportError; end

  class ModelNotFoundError < TransportError; end

  class RateLimitedError < TransportError; end

  class OverloadedError < TransportError; end

  # A failure after a stream's 200 is `Protocol::StreamError`, not a
  # `TransportError`: there is no status left to report.

  # One deployment: a name, a base URL, a credential, and one keep-alive
  # connection shared by every `Provider` on it (Ollama serves three
  # protocols from one port).
  #
  # `name` decides vendor identity: a provider inherits a protocol's vendor
  # only when the server's name matches it.
  class Server
    getter name : String
    getter base_uri : URI
    getter credential : String?

    def initialize(@name : String, base_url : String, @credential : String? = nil,
                   @timeout : Time::Span = 120.seconds)
      @base_uri = URI.parse(base_url)
    end

    # Posts a request and returns the body. A non-2xx status raises the
    # `TransportError` subclass `error_for` chooses, with `detail`, the
    # adapter's error-body decoder, supplying the provider's own words.
    def post(path : String, headers : HTTP::Headers, body : String,
             detail : Proc(String, String?)? = nil) : String
      response = client.post(path, headers: headers, body: body)
      return response.body if response.success?

      explanation = detail.try(&.call(response.body))
      raise error_for(response.status_code, explanation)
    end

    # Posts a request and yields each server-sent event frame as it arrives.
    # The block returns `true` to continue and `false` to stop. Status errors
    # raise as in `post`, before any frame.
    #
    # The shared connection is closed whenever the body is not read to its
    # end: a stop, or a raise from the block or the frame reader. Left open,
    # the next request on this server would read the rest of the body as its
    # own response.
    #
    # Built with `exec` rather than `post` with a block: Wiretap redefines
    # `exec(request, &block)` with a captured block, and the stdlib `post`
    # overload yields inside the block it passes there, which does not
    # compile.
    def stream(path : String, headers : HTTP::Headers, body : String,
               detail : Proc(String, String?)? = nil,
               &block : Streaming::Sse::Frame -> Bool) : Nil
      drained = false
      request = HTTP::Request.new("POST", path, headers, body)

      begin
        client.exec(request) do |response|
          unless response.success?
            error_body = response.body_io.gets_to_end
            drained = true
            raise error_for(response.status_code, detail.try(&.call(error_body)))
          end

          stopped = false
          Streaming::Sse.each_frame(response.body_io) do |frame|
            unless block.call(frame)
              stopped = true
              break
            end
          end
          drained = !stopped
        end
      ensure
        close unless drained
      end
    end

    # The `TransportError` subclass for an HTTP status.
    def error_for(status : Int32, detail : String? = nil) : TransportError
      case status
      when 401, 403 then AuthError.new(@name, status, detail)
      when 404      then ModelNotFoundError.new(@name, status, detail)
      when 429      then RateLimitedError.new(@name, status, detail)
      when .>=(500) then OverloadedError.new(@name, status, detail)
      else               TransportError.new(@name, status, detail)
      end
    end

    def close : Nil
      @client.try &.close
      @client = nil
    end

    private def client : HTTP::Client
      @client ||= HTTP::Client.new(@base_uri).tap do |http|
        http.read_timeout = @timeout
        http.connect_timeout = @timeout
      end
    end

    @client : HTTP::Client? = nil
  end
end
