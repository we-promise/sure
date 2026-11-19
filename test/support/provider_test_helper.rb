module ProviderTestHelper
  def provider_success_response(data)
    Provider::Response.new(
      success?: true,
      data: data,
      error: nil
    )
  end

  # A provider mock that DECLARES it can answer for classification and for a
  # fund's constituents.
  #
  # Both gates call the provider's own declaration, and a bare
  # `mock("provider")` has no stub for it, so a test that reaches a gate with
  # one fails on an unexpected invocation. Most real providers answer false,
  # so a test has to say which side it means, which is what this is for.
  #
  # Pass `classification:` or `constituents:` false to build the incapable side
  # of a boundary deliberately.
  def capable_provider(name = "provider", classification: true, constituents: true)
    provider = mock(name)
    provider.stubs(:supplies_constituents?).returns(constituents)
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
