require "json"
require "./errors"
require "../mpsh/meta"

module Liaison::Protocol
  # Tool-call arguments read from their JSON text, the same way for every
  # protocol. Where the text comes from, and what an absent field means, stay
  # with each protocol's reader.
  module Arguments
    extend self

    # Reads `json` as a JSON object. Blank text is a call with no arguments.
    # Anything else that is not a JSON object raises
    # `MalformedResponseError`, naming `source` and the tool, so a tool never
    # runs on arguments the model did not send.
    def object(json : String, source : String, tool : String) : Hash(String, JSON::Any)
      return {} of String => JSON::Any if json.blank?

      parsed = begin
        JSON.parse(json)
      rescue error : JSON::ParseException
        raise MalformedResponseError.new(source,
          "arguments for tool `#{tool}` are not JSON: #{error.message}")
      end

      parsed.as_h? || raise MalformedResponseError.new(source,
        "arguments for tool `#{tool}` are not a JSON object")
    end

    # `object`, converted to MPSH values.
    def read(json : String, source : String, tool : String) : MPSH::Object
      object(json, source, tool).each_with_object(MPSH::Object.new) do |(key, value), acc|
        acc[key] = to_value(value)
      end
    end

    private def to_value(any : JSON::Any) : MPSH::Value
      case raw = any.raw
      when Nil, Bool, Int64, Float64, String
        raw
      when Array
        raw.map { |item| to_value(item).as(MPSH::Value) }
      when Hash
        raw.each_with_object(MPSH::Object.new) { |(key, item), acc| acc[key] = to_value(item) }
      end
    end
  end
end
