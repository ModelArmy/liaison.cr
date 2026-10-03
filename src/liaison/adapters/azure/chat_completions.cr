require "../chat_completions"

module Liaison
  # Azure OpenAI's Chat Completions surface: `ChatCompletionsAdapter` with
  # Azure's path (the deployment in the URL, a dated `api-version` query) and
  # `api-key` header. Everything else is inherited. See
  # `Provider.for_azure`.
  class AzureChatCompletionsAdapter < ChatCompletionsAdapter
    def initialize(@api_version : String, vendor : String? = nil,
                   reasoning_unit : Capability::ReasoningUnit? = nil,
                   max_tokens_field : Protocol::ChatCompletions::Wire::MaxTokensField = Protocol::ChatCompletions::Wire::MaxTokensField::MaxTokens)
      super(vendor, reasoning_unit, max_tokens_field)
    end

    # `model` is the deployment name. It is also written into the body, where
    # Azure ignores it.
    def path(model : String) : String
      "/openai/deployments/#{URI.encode_path_segment(model)}/chat/completions?api-version=#{@api_version}"
    end

    def headers(credential : String?) : HTTP::Headers
      api_key(credential)
    end
  end
end
