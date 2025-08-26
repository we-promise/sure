module BankProviders
  class Registry
    class << self
      def register(key, klass)
        providers[key.to_sym] = klass
      end

      def for(key, **args)
        klass = providers[key.to_sym]
        raise ArgumentError, "Unknown bank provider: #{key}" unless klass
        klass.new(**args)
      end

      def providers
        @providers ||= {}
      end
    end
  end
end
