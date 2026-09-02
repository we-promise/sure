require "test_helper"

class Assistant::FunctionTest < ActiveSupport::TestCase
  class EmptyEnumFunction < Assistant::Function
    class << self
      def name
        "empty_enum_function"
      end

      def description
        "Test function with data-driven enums"
      end
    end

    def call(params = {})
      {}
    end

    def params_schema
      build_schema(
        required: [ "name" ],
        properties: {
          name: {
            type: "string",
            description: "Property-level enum built from empty user data",
            enum: []
          },
          accounts: {
            type: "array",
            description: "Items-level enum built from empty user data",
            items: { enum: [] },
            minItems: 1,
            uniqueItems: true
          },
          order: {
            enum: [ "asc", "desc" ],
            description: "Static enum that must be preserved"
          }
        }
      )
    end
  end

  setup do
    @function = EmptyEnumFunction.new(users(:family_admin))
  end

  test "drops empty enums so strict providers accept the schema" do
    properties = @function.to_definition[:params_schema][:properties]

    refute properties[:name].key?(:enum)
    assert_equal "string", properties[:name][:type]

    refute properties[:accounts][:items].key?(:enum)
    assert_equal "string", properties[:accounts][:items][:type]
    assert_equal 1, properties[:accounts][:minItems]
  end

  test "preserves populated enums and surrounding schema" do
    schema = @function.to_definition[:params_schema]

    assert_equal [ "asc", "desc" ], schema[:properties][:order][:enum]
    assert_equal [ "name" ], schema[:required]
    assert_equal "object", schema[:type]
  end

  test "keeps populated enum values verbatim, including literal objects and arrays" do
    schema = {
      status: { enum: [ { enum: [] }, [ "nested" ] ] },
      order: { enum: [ "asc" ] }
    }

    pruned = @function.send(:prune_empty_enums, schema)

    assert_equal [ { enum: [] }, [ "nested" ] ], pruned[:status][:enum]
    assert_equal [ "asc" ], pruned[:order][:enum]
  end

  test "no registered function emits an empty enum" do
    user = users(:family_admin)
    user.update!(preferences: (user.preferences || {}).merge("preview_features_enabled" => true))

    function_classes = Assistant.function_classes(user)
    assert_empty Assistant::PREVIEW_FUNCTION_CLASSES - function_classes,
      "expected preview functions to be included in the assertion"

    function_classes.each do |function_class|
      definition = function_class.new(user).to_definition
      assert_no_empty_enums definition[:params_schema], function_class.name
    end
  end

  test "to_ai_time_series rounds to the currency's own precision" do
    value = Struct.new(:trend).new(Struct.new(:current).new(Money.new(0.00000001, "BTC")))
    series = Struct.new(:start_date, :end_date, :interval, :values)
      .new(Date.current - 1, Date.current, "1 day", [ value ])

    result = EmptyEnumFunction.new(nil).send(:to_ai_time_series, series)

    assert_equal "BTC", result[:currency]
    assert_equal 0.00000001, result[:values].first
  end

  private
    def assert_no_empty_enums(node, function_name, path = "params_schema")
      case node
      when Hash
        node.each do |key, value|
          refute key.to_sym == :enum && value == [],
            "#{function_name} emits an empty enum at #{path}.#{key}, which is invalid JSON Schema"
          assert_no_empty_enums(value, function_name, "#{path}.#{key}")
        end
      when Array
        node.each_with_index do |value, index|
          assert_no_empty_enums(value, function_name, "#{path}[#{index}]")
        end
      end
    end
end
