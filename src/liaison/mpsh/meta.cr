module Liaison::MPSH
  # JSON's value model as a plain union rather than `JSON::Any`, so
  # `provider_metadata` and tool arguments are structured without carrying a
  # parse type into the canonical types.
  alias Value = Bool | Int64 | Float64 | String | Array(Value) | Hash(String, Value)?

  # Structured object, e.g. tool-call arguments.
  alias Object = Hash(String, Value)

  # Provider-namespaced side data: `{"openai" => {...}, "anthropic" => {...}}`.
  #
  # The namespacing is the drop logic: a mapper reads only its own key, so
  # foreign data is left behind with no explicit discard step.
  alias Metadata = Hash(String, Object)

  # Mixed into every block and into `Message`.
  module ProviderScoped
    getter provider_metadata : Metadata { Metadata.new }
    setter provider_metadata

    # Everything the named provider needs echoed back, or nil.
    def meta_for(provider : String) : Object?
      @provider_metadata.try &.[provider]?
    end

    def put_meta(provider : String, key : String, value : Value) : Nil
      (provider_metadata[provider] ||= Object.new)[key] = value
    end

    def meta?(provider : String, key : String) : Value?
      meta_for(provider).try &.[key]?
    end
  end
end
