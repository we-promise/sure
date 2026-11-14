# frozen_string_literal: true

require "test_helper"

class Provider::ConnectionDeclarationTest < ActiveSupport::TestCase
  test "every registered adapter declares its connection" do
    undeclared = Provider::Factory.registered_adapters.reject(&:connection_declaration)

    assert_empty undeclared.map(&:name)
  end

  test "each declaration names a family connection and its accounts association" do
    Provider::Factory.connection_declarations.each do |declaration|
      family_association = Family.reflect_on_association(declaration[:association])
      assert family_association, "Family has no #{declaration[:association]} for #{declaration[:key]}"
      assert_equal declaration[:type], family_association.klass.name

      item_class = declaration[:type].constantize
      assert item_class.reflect_on_association(declaration[:accounts]),
             "#{declaration[:type]} has no #{declaration[:accounts]}"
      if declaration[:linked_accounts]
        assert item_class.reflect_on_association(declaration[:linked_accounts]),
               "#{declaration[:type]} has no #{declaration[:linked_accounts]}"
      end
    end
  end

  test "irregular connections declare their own associations" do
    declarations = Provider::Factory.connection_declarations.index_by { |declaration| declaration[:key] }

    assert_equal :financekit_account_lineages, declarations.fetch("financekit")[:accounts]
    assert_equal :linked_accounts, declarations.fetch("snaptrade")[:linked_accounts]
    assert_not declarations.fetch("brex").key?(:linked_accounts)
  end

  test "an adapter that registers no provider type declares no connection" do
    assert_not Provider::Factory.connection_declarations.any? { |declaration| declaration[:key] == "plaid_eu" }
    assert_equal 1, Provider::Factory.connection_declarations.count { |declaration| declaration[:type] == "PlaidItem" }
  end

  test "connection status providers are the declarations in key order" do
    keys = ProviderConnectionStatus::PROVIDERS.map { |provider| provider[:key] }

    assert_equal Provider::Factory.connection_declarations, ProviderConnectionStatus::PROVIDERS
    assert_equal keys.sort, keys
    assert_equal keys.uniq, keys
  end

  # File order is not key order once a key is a prefix of another followed by a
  # digit ("foo2_adapter.rb" sorts before "foo_adapter.rb"), so the order must
  # come from the keys, not the directory listing.
  test "declarations are sorted by key whatever order the adapter files arrive in" do
    files = Provider::Factory.send(:adapter_files)
    Provider::Factory.stubs(:adapter_files).returns(files.reverse)

    keys = Provider::Factory.connection_declarations.map { |declaration| declaration[:key] }

    assert_equal keys.sort, keys
  end

  test "family connections are listed alphabetically by provider" do
    providers = ProviderConnectionStatus.for_family(families(:dylan_family)).map { |connection| connection[:provider] }

    assert_operator providers.index("brex"), :<, providers.index("mercury")
    assert_equal providers.chunk_while { |a, b| a == b }.map(&:first).sort,
                 providers.chunk_while { |a, b| a == b }.map(&:first)
  end
end
