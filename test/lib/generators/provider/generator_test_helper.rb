# Run without booting Rails or connecting to a database:
# bundle exec ruby -Itest test/lib/generators/provider/account_data_generator_test.rb
require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "rails/generators"
require_relative "../../../../app/models/provider"
require_relative "../../../../app/models/provider/account_data"
require_relative "../../../../app/models/provider/account_data/definition"
require_relative "../../../../app/models/provider/account_data/adapter"
require_relative "../../../../lib/generators/provider/account_data/account_data_generator"

class ProviderGeneratorTestCase < Minitest::Test
  def setup
    super
    @destination = Dir.mktmpdir("sure-account-data-generator-")
  end

  def teardown
    Provider::AccountData.send(:remove_const, :AcmeBank) if Provider::AccountData.const_defined?(:AcmeBank, false)
    FileUtils.remove_entry(@destination) if @destination && File.directory?(@destination)
    super
  end

  private
    def generator_class
      Provider::AccountDataGenerator
    end

    def generate(arguments = [ "acme_bank" ], options = {}, behavior: :invoke)
      capture_io do
        generator_class.new(arguments, options, destination_root: @destination, behavior: behavior).invoke_all
      end
    end

    def generated_files
      Dir.glob("**/*", base: @destination).select { |path| File.file?(File.join(@destination, path)) }.sort
    end

    def expected_files
      %w[
        app/models/provider/account_data/acme_bank.rb
        app/models/provider/account_data/acme_bank/client.rb
        docs/providers/acme_bank.md
        test/models/provider/account_data/acme_bank_test.rb
      ].sort
    end

    def read_generated(path)
      File.read(File.join(@destination, path))
    end

    def load_generated_adapter
      load File.join(@destination, "app/models/provider/account_data/acme_bank.rb")
      load File.join(@destination, "app/models/provider/account_data/acme_bank/client.rb")
      Provider::AccountData::AcmeBank
    end

    def assert_generated_ruby_compiles
      generated_files.grep(/\.rb\z/).each do |path|
        RubyVM::InstructionSequence.compile_file(File.join(@destination, path))
      rescue SyntaxError => error
        flunk "#{path} does not compile: #{error.message}"
      end
    end

    def assert_command_rejected(arguments)
      error = nil
      output = capture_io do
        begin
          generator_class.start(arguments, destination_root: @destination)
        rescue Thor::Error => exception
          error = exception
        rescue SystemExit => exception
          raise if exception.success?

          error = exception
        end
      end.join
      assert(error || output.match?(/unknown|invalid|must|could not|cannot/i), "Expected an invalid command to be rejected: #{output}")
      assert_empty generated_files, "Invalid input must be rejected before generating any files"
    end
end
