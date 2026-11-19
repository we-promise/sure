module ProviderTestHelper
  def provider_success_response(data)
    Provider::Response.new(
      success?: true,
      data: data,
      error: nil
    )
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
end
