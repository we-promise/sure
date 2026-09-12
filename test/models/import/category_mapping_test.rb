require "test_helper"

class Import::CategoryMappingTest < ActiveSupport::TestCase
  setup do
    @mapping = import_mappings(:one)
  end

  test "selectable_values groups subcategories immediately after their parent" do
    options = @mapping.selectable_values

    parent_index = options.index { |_label, id| id == categories(:food_and_drink).id }
    child_index = options.index { |_label, id| id == categories(:subcategory).id }

    assert_not_nil parent_index
    assert_not_nil child_index
    assert_equal parent_index + 1, child_index
  end

  test "selectable_values still prepends 'Add as new category' when key is present" do
    options = @mapping.selectable_values

    assert_equal "Add as new category", options.first.first
    assert_equal Import::Mapping::CREATE_NEW_KEY, options.first.last
  end

  test "create_mappable! uses root parent when parent_name matches an existing subcategory" do
    import = @mapping.import

    # First, create a mapping where "Insurance" becomes a subcategory under "Auto"
    m1 = import.mappings.create!(key: "Auto:Insurance", create_when_empty: true, type: "Import::CategoryMapping")
    m1.create_mappable!

    insurance_sub = import.family.categories.find_by!(name: "Insurance")
    assert insurance_sub.subcategory?
    assert_equal "Auto", insurance_sub.parent.name

    # Now create a mapping where "Insurance" is the parent_name in "Insurance:ADD"
    m2 = import.mappings.create!(key: "Insurance:ADD", create_when_empty: true, type: "Import::CategoryMapping")
    assert_nothing_raised do
      m2.create_mappable!
    end

    add_sub = import.family.categories.find_by!(name: "ADD")
    assert add_sub.subcategory?
    assert_equal "Auto", add_sub.parent.name
  end

  test "create_mappable! atomically creates shared root parent during concurrent imports" do
    family = families(:empty)
    parent_name = "Concurrent Parent #{SecureRandom.hex(4)}"
    child_names = 8.times.map { |index| "Concurrent Child #{index} #{SecureRandom.hex(4)}" }
    ready = Queue.new
    start = Queue.new
    errors = Queue.new
    import_ids = Queue.new

    threads = child_names.map do |child_name|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          import = TransactionImport.create!(family: Family.find(family.id), status: :pending)
          import_ids << import.id

          mapping = import.mappings.create!(
            key: "#{parent_name}:#{child_name}",
            create_when_empty: true,
            type: "Import::CategoryMapping"
          )

          ready << true
          start.pop
          mapping.create_mappable!
        rescue => error
          errors << error
        end
      end
    end

    child_names.size.times { ready.pop }
    child_names.size.times { start << true }
    threads.each(&:join)

    thread_errors = []
    thread_errors << errors.pop until errors.empty?

    assert_empty thread_errors, -> { thread_errors.map { |error| "#{error.class}: #{error.message}" }.join("\n") }
    assert_equal 1, family.categories.roots.where(name: parent_name).count

    parent = family.categories.roots.find_by!(name: parent_name)
    assert_equal child_names.sort, parent.subcategories.where(name: child_names).pluck(:name).sort
  ensure
    if defined?(child_names)
      Category.where(family: family, name: child_names).destroy_all
    end

    if defined?(parent_name)
      Category.where(family: family, name: parent_name).destroy_all
    end

    if defined?(import_ids)
      ids = []
      ids << import_ids.pop until import_ids.empty?
      Import.where(id: ids).destroy_all
    end
  end
end
