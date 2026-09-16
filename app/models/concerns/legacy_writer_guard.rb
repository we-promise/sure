# Explicit boundaries for legacy item methods. Native adapters never include this
# concern; the fence validates each source against the migration manifest.
module LegacyWriterGuard
  extend ActiveSupport::Concern

  class_methods do
    private
      def guard_legacy_writes(**declarations)
        registered = instance_variable_get(:@legacy_writer_guard_definitions) || {}
        additions = declarations.filter_map do |method_name, operation|
          unless method_name.is_a?(Symbol) && %i[ingest publish].include?(operation)
            raise ArgumentError, "Legacy guards require explicit ingest or publish declarations"
          end
          if registered.key?(method_name)
            raise ArgumentError, "Legacy guard operation cannot change" unless registered.fetch(method_name) == operation
            next
          end
          unless public_instance_methods(false).include?(method_name) && instance_method(method_name).owner == self
            raise ArgumentError, "Declare a guard after defining its own public method"
          end
          [ method_name, operation, instance_method(method_name) ]
        end
        return if additions.empty?

        wrapper = Module.new
        additions.each do |method_name, operation, original|
          wrapper.define_method(method_name) do |*arguments, **keywords, &block|
            Provider::AccountData::LegacyWriterFence.with_item(self, operation: operation) do |current|
              original.bind_call(current, *arguments, **keywords, &block)
            end
          end
        end
        prepend wrapper
        @legacy_writer_guard_definitions = registered.merge(declarations).freeze
      end
  end
end
