require "http/server"
require "json"

# A local `HTTP::Server` for specs that need a real socket.
#
# It serves outside `Wiretap.intercept`, so nothing is recorded or replayed and
# no network is reached. What it answers with is the spec's choice; a body
# taken from a committed transcript keeps the answer recorded rather than
# hand-written.
module Loopback
  # Starts a server answering every request with `handler`, yields its base
  # URL, and stops it afterwards.
  #
  # Whatever request body `handler` leaves unread is read after it, as a
  # provider's server would. `HTTP::Server` instead closes a keep-alive
  # connection whose request body was not read, and the client's next request
  # on it fails with an end-of-response error.
  def self.serve(handler : HTTP::Server::Context ->, &)
    http = HTTP::Server.new do |context|
      handler.call(context)
      context.request.body.try(&.skip_to_end)
    end
    address = http.bind_tcp("127.0.0.1", 0)
    spawn { http.listen }

    begin
      yield "http://127.0.0.1:#{address.port}"
    ensure
      http.close
    end
  end

  # The response body of interaction `index` in `spec/transcripts/<name>.json`.
  def self.recorded_body(name : String, index : Int32 = 0) : String
    transcript = JSON.parse(File.read(File.join("spec", "transcripts", "#{name}.json")))
    transcript["interactions"][index]["response"]["body"].as_s
  end
end
