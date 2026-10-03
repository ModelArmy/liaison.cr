require "./function"
require "./mpsh/message"
require "./mpsh/repair"

module Liaison
  # A collection of `Function`s, used at both ends of a turn: `#tools` produces
  # the declarations a request carries, `#dispatch` turns a reply's calls into
  # the results the next request carries.
  #
  # ```
  # toolbox = Liaison::Toolbox.new([Weather.new, Clock.new])
  #
  # loop do
  #   reply, _ = client.send(session, model, options: Options.new(tools: toolbox.tools))
  #   session << reply
  #
  #   results = toolbox.dispatch(reply)
  #   break unless results
  #   session << results
  # end
  # ```
  #
  # It holds functions and pairs results with calls. It does not own the
  # session, decide when a conversation ends, or loop: the turn loop stays the
  # caller's.
  class Toolbox
    getter functions : Array(Function)

    # Raises `ArgumentError` if two functions share a name, since a call names
    # one tool.
    def initialize(@functions : Array(Function))
      @by_name = {} of String => Function
      @functions.each do |function|
        if @by_name.has_key?(function.name)
          raise ArgumentError.new("duplicate tool name in toolbox: #{function.name}")
        end
        @by_name[function.name] = function
      end
    end

    # The declarations, for `Options#tools`.
    def tools : Array(Tool)
      @functions.map(&.to_tool)
    end

    # Runs every call in `reply`, in order and one at a time, and returns one
    # user-role message of results, or `nil` when there is nothing to run
    # (a turn loop's exit condition).
    #
    # Reads the repaired reply, so a cut turn's calls are not run: their
    # results would answer calls the repaired session no longer holds.
    # Server-executed calls are skipped, since the reply already carries their
    # results.
    def dispatch(reply : MPSH::Message) : MPSH::Message?
      repaired = MPSH::Repair.repaired(reply)
      return unless repaired

      calls = repaired.content.select(MPSH::ToolCallBlock).reject(&.server_executed?)
      return if calls.empty?

      MPSH::Message.new(MPSH::Role::User, calls.map { |call| run(call).as(MPSH::Block) })
    end

    # Every call gets a result, including one naming a tool this toolbox lacks
    # and one whose tool raised, so the session stays `Repair.sendable?`.
    private def run(call : MPSH::ToolCallBlock) : MPSH::ToolResultBlock
      function = @by_name[call.name]?
      return failed(call, "no tool named #{call.name} is available") unless function

      MPSH::ToolResultBlock.new(call.call_id, function.call(call.arguments))
    rescue error : Function::Failure
      failed(call, error.message || "the tool reported a failure")
    rescue error : Exception
      # Sets `is_error` as well as `exception`: no mapper sends `exception`, so
      # `is_error` is what the model sees and `exception` what an archive
      # keeps.
      failed(call, "the tool raised: #{error.message}", exception: error.inspect)
    end

    private def failed(call : MPSH::ToolCallBlock, text : String,
                       exception : String? = nil) : MPSH::ToolResultBlock
      MPSH::ToolResultBlock.new(call.call_id,
        [MPSH::TextBlock.new(text).as(MPSH::Block)],
        is_error: true, exception: exception)
    end
  end
end
