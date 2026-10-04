require "../spec_helper"
require "../support/loopback"

# What `Server#stream` leaves on its shared connection for the next request.
#
# Every other streaming spec replays through Wiretap, which never opens a
# socket, so none can see a body left half-read. This one serves a `Loopback`
# server instead: no transcript, no network.
#
# The stream is flushed frame by frame, so it arrives chunked as a real one
# does. Each example ends by calling the same `Server` again; a connection
# left mid-body fails that call, not the one that left it.

private def answer(context : HTTP::Server::Context) : Nil
  case context.request.path
  when "/stream"
    context.response.content_type = "text/event-stream"
    %w(one two three).each do |word|
      context.response.print "data: #{word}\n\n"
      context.response.flush
    end
  when "/fail"
    context.response.status_code = 503
    context.response.print %({"error":{"message":"overloaded"}})
  else
    context.response.print "pong"
  end
end

private def with_loopback(&)
  Loopback.serve(->answer(HTTP::Server::Context)) do |url|
    server = Liaison::Server.new("loopback", url)
    begin
      yield server
    ensure
      server.close
    end
  end
end

private def ping(server : Liaison::Server) : String
  server.post("/ping", HTTP::Headers.new, "")
end

describe Liaison::Server do
  describe "#stream" do
    it "reads every frame, and leaves the connection usable" do
      with_loopback do |server|
        read = [] of String
        server.stream("/stream", HTTP::Headers.new, "") { |frame| read << frame.data; true }

        read.should eq(%w(one two three))
        ping(server).should eq("pong")
      end
    end

    it "leaves the connection usable after the block stops" do
      with_loopback do |server|
        server.stream("/stream", HTTP::Headers.new, "") { false }

        ping(server).should eq("pong")
      end
    end

    it "leaves the connection usable after the block raises" do
      with_loopback do |server|
        expect_raises(Exception, "handler failed") do
          server.stream("/stream", HTTP::Headers.new, "") { raise "handler failed" }
        end

        ping(server).should eq("pong")
      end
    end

    it "leaves the connection usable after a status error" do
      with_loopback do |server|
        expect_raises(Liaison::OverloadedError) do
          server.stream("/fail", HTTP::Headers.new, "") { true }
        end

        ping(server).should eq("pong")
      end
    end
  end
end
