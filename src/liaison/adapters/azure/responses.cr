require "../responses"

module Liaison
  # Azure OpenAI's Responses surface: `ResponsesAdapter` with Azure's path
  # and `api-key` header.
  class AzureResponsesAdapter < ResponsesAdapter
    def initialize(@api_version : String, vendor : String? = nil,
                   reasoning_unit : Capability::ReasoningUnit? = nil)
      super(vendor, reasoning_unit)
    end

    # Unlike Chat Completions, the deployment is not in the path: it travels in
    # the body as `model`. Confirmed against a live deployment, since Azure's
    # docs disagree with themselves.
    def path(model : String) : String
      "/openai/responses?api-version=#{@api_version}"
    end

    def headers(credential : String?) : HTTP::Headers
      api_key(credential)
    end
  end
end
