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
  # The classification gate calls `supplies_classification?` on the provider,
  # and a bare `mock("provider")` has no stub for it, so a test that reaches
  # the gate with one fails on an unexpected invocation. Seven of the ten real
  # providers answer false, so a test has to say which side it means, which is
  # what this is for.
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

  # The errors a provider hands its default_error_transformer, so a test can
  # check which failure produced a failed response, not only that one did.
  def capture_transformed_errors(provider)
    seen = []
    provider.singleton_class.prepend(Module.new do
      define_method(:default_error_transformer) do |error|
        seen << error
        super(error)
      end
    end)
    seen
  end

  # The read timeout each request a provider sends carries, in order, so a test
  # can check a per-request override, not only the client's default.
  def capture_request_timeouts(provider)
    seen = []
    recorder = Class.new(Faraday::Middleware) do
      define_method(:on_request) { |env| seen << env.request.timeout }
    end
    provider.send(:client).builder.insert(0, recorder)
    seen
  end
end
