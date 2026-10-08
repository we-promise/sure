module ProviderTestHelper
  def provider_success_response(data)
    Provider::Response.new(
      success?: true,
      data: data,
      error: nil
    )
  end

  # A provider mock that DECLARES it can answer for classification.
  #
  # The classification fetch is gated on the provider's own declaration, so a
  # bare `mock("provider")` is an INCAPABLE provider: it is never asked for a
  # classification, and a test expecting that fetch fails. That is the right
  # default -- seven of the ten real providers supply none -- but it means a
  # test that wants the fetch to happen has to say so, which is what this is for.
  #
  # Pass `classification: false` to build the incapable side of a boundary
  # deliberately.
  def capable_provider(name = "provider", classification: true)
    provider = mock(name)
    provider.stubs(:supplies_classification?).returns(classification)
    provider
  end

  def provider_error_response(error)
    Provider::Response.new(
      success?: false,
      data: nil,
      error: error
    )
  end
end
