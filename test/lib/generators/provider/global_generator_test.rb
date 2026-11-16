require "test_helper"

# Every hand-written *_item.rb / *_account.rb model in app/models encrypts its raw
# provider payload columns (they hold full API responses, which can contain secrets).
# This template generates the starting point for every *new* global provider, so a gap
# here means every future global provider ships with unencrypted payloads until someone
# notices. Mirrors the equivalent family_generator_test.rb coverage for the family flow.
class Provider::GlobalGeneratorTest < ActiveSupport::TestCase
  def template_path(name)
    File.expand_path("../../../../../lib/generators/provider/global/templates/#{name}", __FILE__)
  end

  test "item model template includes Encryptable and encrypts raw payload columns" do
    template = File.read(template_path("global_item_model.rb.tt"))

    assert_includes template, "Encryptable"
    encryption_block = template[/if encryption_ready\?.*?\n  end/m]

    assert encryption_block, "expected an `if encryption_ready?` block in global_item_model.rb.tt"
    assert_includes encryption_block, "encrypts :raw_payload"
    assert_includes encryption_block, "encrypts :raw_institution_payload"
  end

  test "account model template includes Encryptable and encrypts raw payload columns" do
    template = File.read(template_path("global_account_model.rb.tt"))

    assert_includes template, "Encryptable"
    encryption_block = template[/if encryption_ready\?.*?\n  end/m]

    assert encryption_block, "expected an `if encryption_ready?` block in global_account_model.rb.tt"
    assert_includes encryption_block, "encrypts :raw_payload"
    assert_includes encryption_block, "encrypts :raw_transactions_payload"
  end
end
