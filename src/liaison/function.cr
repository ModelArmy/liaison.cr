require "./mpsh/block"
require "./options"

module Liaison
  # A tool the caller can declare and run: a `Tool` declaration plus its
  # handler. Hand instances to a `Toolbox`, which produces the declarations
  # for a request and the results for a reply.
  # ```
  # class Weather
  #   include Liaison::Function
  #
  #   def name : String
  #     "get_weather"
  #   end
  #
  #   def description : String?
  #     "Look up the current weather in a city"
  #   end
  #
  #   def parameters : String
  #     %({"type":"object","properties":{"city":{"type":"string"}},"required":["city"]})
  #   end
  #
  #   def call(arguments : MPSH::Object) : Array(MPSH::Block)
  #     city = arguments["city"]?.as?(String) || "somewhere"
  #     [MPSH::TextBlock.new("18C, light rain in #{city}").as(MPSH::Block)]
  #   end
  # end
  # ```
  module Function
    # Matched against `ToolCallBlock#name`, so it must be what `parameters`
    # describes and what the model was told.
    abstract def name : String

    abstract def description : String?

    # The JSON Schema, as text; see `Tool`.
    abstract def parameters : String

    # Runs the tool. The returned blocks become the content of one
    # `MPSH::ToolResultBlock`, so a tool can return images, audio or files.
    #
    # Arguments arrive parsed. `MPSH::Value` is a plain union, not `JSON::Any`:
    # read it with `as?(String)` and the like.
    #
    # Raise `Failure` to report that the tool ran and could not do the job; its
    # message reaches the model. Any other exception is caught by `Toolbox` and
    # recorded as a dispatch that raised. Neither ends the turn.
    #
    # An instance usually lives for the whole process, so state written to an
    # instance variable here leaks between sessions. Keep per-call state
    # local.
    abstract def call(arguments : MPSH::Object) : Array(MPSH::Block)

    # The declaration form, for `Options#tools`.
    def to_tool : Tool
      Tool.new(name, description, parameters)
    end

    # Reported to the model as a failed tool result, with `message` as its
    # text.
    class Failure < Exception
    end
  end
end
