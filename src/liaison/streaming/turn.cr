module Liaison::Streaming
  # The second block parameter: a handle on the turn in progress, so a caller
  # watching events can ask for it to end.
  #
  # ```
  # reply, report = client.send(session, model) do |event, turn|
  #   turn.stop if user_pressed_escape?
  #   present(event)
  # end
  # ```
  #
  # Stopping is cooperative: `stop` sets a flag, and the client stops at the
  # next frame boundary and finishes through the same path as a complete
  # stream. Whatever arrived is translated; nothing is thrown away. If the
  # stream had not finished, the reply's `ending` is `Stopped`, and it is
  # repaired like any cut turn.
  #
  # `stop` takes no cause: the caller who stopped already knows it.
  class Turn
    def initialize
      @stopped = false
    end

    # Asks for the turn to end after the current frame. Idempotent.
    def stop : Nil
      @stopped = true
    end

    def stopped? : Bool
      @stopped
    end
  end
end
