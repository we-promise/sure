# frozen_string_literal: true

# The contract every chain implementation fulfils. An adapter is the only
# place in the codebase allowed to know how a specific chain works; it turns
# that knowledge into an Onchain::Snapshot and nothing else.
module Onchain::ChainAdapter
  # @param address [String]
  # @return [Boolean] whether the address is well-formed for this chain.
  #   Must never make a network call.
  def valid_address?(_address)
    raise NotImplementedError, "#{self.class} must implement #valid_address?"
  end

  # The form of an address this chain considers canonical, so that two spellings
  # of the same address cannot become two wallets. Case matters on some chains and
  # not others, which is why only the adapter can answer it.
  def canonical_address(address)
    address.to_s.strip
  end

  # @param address [String]
  # @return [Onchain::Snapshot]
  def fetch_snapshot(_address)
    raise NotImplementedError, "#{self.class} must implement #fetch_snapshot"
  end

  # The error classes this chain's data sources raise, as
  # [rate limit class(es), base class(es)]. Either entry may be a single class or
  # an array, because a chain may read through more than one backend.
  def provider_error_classes
    []
  end

  # Translates a data source's own errors into Onchain::Chains errors. Anything
  # else — a bug in our code — is left alone so it surfaces as the unexpected
  # failure it is instead of being reported to the user as a dead explorer.
  def wrap_provider_errors
    yield
  rescue Onchain::Chains::Error
    raise
  rescue StandardError => e
    rate_limit_classes, base_classes = provider_error_classes
    raise Onchain::Chains::RateLimitedError, e.message if Array(rate_limit_classes).any? { |klass| e.is_a?(klass) }
    raise Onchain::Chains::UnreachableError, e.message if Array(base_classes).any? { |klass| e.is_a?(klass) }

    raise
  end

  # Reads transfer history without letting its failure cost the balances.
  #
  # A balance is one bounded request and is what a wallet fundamentally is;
  # history is paginated, an order of magnitude more expensive, and the first
  # thing a throttled public endpoint refuses. Failing the whole snapshot over it
  # means a wallet that could have been valued correctly shows nothing at all —
  # on some free endpoints, permanently.
  #
  # Returns nil when the history could not be read, which the caller reports as
  # an incomplete history rather than as an empty one. Anything that is not the
  # data source failing still raises: a bug here must not be silently swallowed.
  def best_effort_movements
    yield
  rescue Onchain::Chains::Error
    raise
  rescue StandardError => e
    rate_limit_classes, base_classes = provider_error_classes
    known = Array(rate_limit_classes).any? { |klass| e.is_a?(klass) } ||
      Array(base_classes).any? { |klass| e.is_a?(klass) }
    raise unless known

    Rails.logger.warn("#{self.class.name} - history unavailable, keeping balances only: #{e.class}")
    nil
  end

  # Whether this address is worth tracking on this chain, answered with at most
  # ONE bounded request and never by reading paginated history. Only chains that
  # share an address format with other chains (every EVM network) need to
  # override this; elsewhere a well-formed address is answer enough.
  #
  # Three answers, not two: true, false, and nil for "could not tell" — a source
  # that timed out or refused has not reported an empty address. An override
  # that collapses the third into false lets detection settle on another chain
  # without asking, which is how a wallet gets linked to the wrong network.
  def has_activity?(address)
    valid_address?(address)
  end
end
