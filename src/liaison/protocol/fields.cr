require "json"
require "./errors"

module Liaison::Protocol
  # Reads fields from JSON a provider sent, where any value may have any
  # shape. Each reader takes a path of keys and returns `nil` when a step is
  # missing or is not an object, so a wrong shape reads as an absent field and
  # each caller decides whether that field was required.
  #
  # ```
  # Fields.string(payload, "error", "message") # => "overloaded" or nil
  # ```
  module Fields
    extend self

    # Parses `text` as a JSON object. Raises `MalformedResponseError` naming
    # `source` when it is not JSON or not an object.
    def parse_object(text : String, source : String) : JSON::Any
      parsed = begin
        JSON.parse(text)
      rescue error : JSON::ParseException
        raise MalformedResponseError.new(source, "response body is not JSON: #{error.message}")
      end

      return parsed if parsed.as_h?
      raise MalformedResponseError.new(source, "response body is not a JSON object")
    end

    # Parses `text` as a JSON object, or `nil` when it is not JSON or not an
    # object: for a streamed frame, which is skipped like a keep-alive, and
    # for an error body, which may be anything.
    def parse_object?(text : String) : JSON::Any?
      parsed = JSON.parse(text)
      parsed if parsed.as_h?
    rescue JSON::ParseException
      nil
    end

    # The value at `keys`, whatever its shape.
    def at(any : JSON::Any?, *keys : String) : JSON::Any?
      keys.reduce(any) { |value, key| value.try(&.as_h?).try(&.[key]?) }
    end

    # The object at `keys`.
    def object(any : JSON::Any?, *keys : String) : JSON::Any?
      value = at(any, *keys)
      value if value.try(&.as_h?)
    end

    def string(any : JSON::Any?, *keys : String) : String?
      at(any, *keys).try(&.as_s?)
    end

    def int(any : JSON::Any?, *keys : String) : Int32?
      at(any, *keys).try(&.as_i?)
    end

    def bool(any : JSON::Any?, *keys : String) : Bool?
      at(any, *keys).try(&.as_bool?)
    end

    def array(any : JSON::Any?, *keys : String) : Array(JSON::Any)?
      at(any, *keys).try(&.as_a?)
    end
  end
end
