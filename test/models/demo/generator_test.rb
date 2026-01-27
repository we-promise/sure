require "test_helper"

class Demo::GeneratorTest < ActiveSupport::TestCase
  test "clear_existing_data! clears only demo data by default" do
    cleaner = Minitest::Mock.new
    cleaner.expect(:destroy_demo_data!, true)

    Demo::DataCleaner.stub(:new, cleaner) do
      Demo::Generator.new(seed: 123).send(:clear_existing_data!)
    end

    assert cleaner.verify
  end

  test "clear_existing_data! can clear everything when flagged" do
    cleaner = Minitest::Mock.new
    cleaner.expect(:destroy_everything!, true)

    Demo::DataCleaner.stub(:new, cleaner) do
      Demo::Generator.new(seed: 456).send(:clear_existing_data!, clear_all: true)
    end

    assert cleaner.verify
  end
end
