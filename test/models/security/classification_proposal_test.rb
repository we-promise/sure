require "test_helper"

# Classification defaults fill what an instrument's own shape implies, and a
# provider fills what it answers for. Everything else -- every ETF, every country
# the region config does not name -- is left unclassified on purpose. This is the
# path for those.
#
# The rule the whole model exists to enforce: the assistant proposes, a person
# approves. A proposal is never a classification until someone says so, because
# `classification_source` exists so a figure in an allocation chart can be traced
# to whoever asserted it.
class Security::ClassificationProposalTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @security = securities(:aapl)
    @family = families(:dylan_family)
  end

  # ------------------------------------------------------------- proposing

  test "a proposal is stored pending, and changes nothing about the security" do
    proposal = propose(asset_class: "equity", asset_sub_class: "stock", sector: "Technology")

    assert proposal.pending?
    assert_nil @security.reload.asset_class, "proposing classified the security"
    assert_nil @security.classification_source
  end

  # The user's own answer is not second-guessed.
  test "a manually classified security cannot be proposed for" do
    @security.update!(asset_class: "fixed_income", classification_source: "manual")

    proposal = Security::ClassificationProposal.new(
      security: @security, family: @family, asset_class: "equity"
    )

    assert_not proposal.valid?
    assert_includes proposal.errors[:security], "has already been classified by hand"
  end

  test "a locked security cannot be proposed for" do
    @security.update!(classification_locked: true)

    proposal = Security::ClassificationProposal.new(
      security: @security, family: @family, asset_class: "equity"
    )

    assert_not proposal.valid?
  end

  # A proposal that could not be approved must not be storable: the vocabularies
  # are database check constraints on `securities`, so storing an unapprovable
  # proposal only defers the failure to approval time.
  test "a proposal outside the vocabulary is refused" do
    %i[asset_class asset_sub_class region].each do |field|
      proposal = Security::ClassificationProposal.new(
        security: @security, family: @family, field => "nonsense"
      )

      assert_not proposal.valid?, "#{field} accepted a value outside its vocabulary"
      assert_includes proposal.errors[field], "is not included in the list"
    end
  end

  test "re-proposing for the same security replaces rather than duplicating" do
    propose(asset_class: "equity", sector: "First answer")

    assert_no_difference "Security::ClassificationProposal.count" do
      propose(asset_class: "commodity", sector: "Second answer")
    end

    proposal = Security::ClassificationProposal.sole
    assert_equal "commodity", proposal.asset_class
    assert_equal "Second answer", proposal.sector
  end

  # A fresh answer is a fresh question for the person: re-proposing after a
  # rejection puts the replaced proposal back in front of them.
  # A person's decision stands: re-proposing does not reopen a rejection nor
  # erase an approval, and the caller learns it from `pending?`.
  test "re-proposing after a rejection leaves the rejection in place" do
    propose(asset_class: "equity").reject!

    proposal = propose(asset_class: "commodity")

    assert proposal.reload.rejected?, "a re-proposal reopened a rejected proposal"
    assert_equal "equity", proposal.asset_class
  end

  test "re-proposing after an approval leaves the approval in place" do
    propose(asset_class: "equity", asset_sub_class: "stock").approve!

    proposal = propose(asset_class: "commodity")

    assert proposal.reload.approved?, "a re-proposal erased the record of an approval"
    assert_equal "equity", @security.reload.asset_class
  end

  # An empty proposal that was storable and approvable would stamp
  # `classification_source: "ai"` on a security with nothing classified. Because
  # "ai" outranks "provider" in the precedence order (default -> provider -> ai
  # -> manual), that security could then never be classified by a provider again
  # -- a permanent lock-out bought with no information at all.
  test "a proposal that answers nothing is refused" do
    proposal = Security::ClassificationProposal.new(security: @security, family: @family)

    assert_not proposal.valid?
    assert_includes proposal.errors[:base], "must propose at least one classification"
  end

  test "a proposal carrying only a rationale is refused" do
    proposal = Security::ClassificationProposal.new(
      security: @security, family: @family, rationale: "Looks like a tech stock."
    )

    assert_not proposal.valid?
  end

  # The replacement reads the row it overwrites under a lock. A copy read
  # before another proposal added a sector would leave that sector in place:
  # only changed columns are written, and nil over nil is no change.
  test "a replacement clears an answer written since its row was read" do
    proposal = propose(region: "europe")
    stale = Security::ClassificationProposal.find(proposal.id)
    Security::ClassificationProposal.where(id: proposal.id).update_all(sector: "Technology")
    Security::ClassificationProposal.stubs(:find_by).returns(stale)

    propose(region: "north_america")

    proposal.reload
    assert_equal "north_america", proposal.region
    assert_nil proposal.sector
  end

  test "a proposal naming a column it does not answer is refused" do
    assert_raises(ArgumentError) { propose(region: "europe", status: "approved") }
    assert_equal 0, Security::ClassificationProposal.count
  end

  # Postgres refuses a NUL in a text column, so it is refused as invalid
  # rather than failing at the INSERT.
  test "a proposal with a NUL in its sector or rationale is refused" do
    assert_raises(ActiveRecord::RecordInvalid) { propose(sector: "Tech\0nology") }
    assert_raises(ActiveRecord::RecordInvalid) { propose(region: "europe", rationale: "Listed\0 in Europe") }
  end

  test "a proposal answering a single field is enough" do
    assert Security::ClassificationProposal.new(
      security: @security, family: @family, region: "europe"
    ).valid?
  end

  # Blank is "not answered" everywhere else in this model, so a blank
  # vocabulary answer is stored as no answer rather than refused.
  test "a blank vocabulary answer is stored as no answer" do
    proposal = propose(asset_class: "equity", asset_sub_class: "", region: "", sector: "")

    assert proposal.pending?
    assert_equal "equity", proposal.reload.asset_class
    assert_nil proposal.asset_sub_class
    assert_nil proposal.region
    assert_nil proposal.sector

    blank_class = Security::ClassificationProposal.new(security: @security, family: @family, asset_class: "", region: "europe")
    assert blank_class.valid?, blank_class.errors.full_messages.to_sentence
    assert_nil blank_class.asset_class
  end

  # ------------------------------------------------------- lifecycle safety

  # `family.destroy` is reached by User#purge, InactiveFamilyCleanerJob,
  # Admin::FamiliesController#destroy and Demo::DataCleaner. A proposal row held
  # a foreign key nothing cascaded, so any family that had ever been offered a
  # classification became undeletable.
  test "a family with a proposal can still be destroyed" do
    family = Family.create!(name: "Doomed", currency: "USD")
    Security::ClassificationProposal.propose!(
      security: @security, family: family, asset_class: "equity"
    )

    assert_difference "Security::ClassificationProposal.count", -1 do
      family.destroy!
    end

    assert Security.exists?(@security.id), "destroying the family took the shared security with it"
  end

  # Same shape from the other side: the duplicate-security merge in
  # lib/tasks/securities.rake destroys a security.
  test "a security with a proposal can still be destroyed" do
    doomed = Security.create!(ticker: "DOOMED", exchange_operating_mic: "XNAS")
    Security::ClassificationProposal.propose!(
      security: doomed, family: @family, asset_class: "equity"
    )

    assert_difference "Security::ClassificationProposal.count", -1 do
      doomed.destroy!
    end
  end

  # -------------------------------------------------------------- approving

  # Checked against whatever the in-memory object last read, the status lets
  # two requests on one proposal both pass. An approve racing a reject would
  # then leave the security classified "ai" behind a row saying "rejected" --
  # the state #reject!'s own comment says it prevents.
  #
  # Simulated deterministically rather than with threads: the row is moved
  # underneath the object, which is exactly what the losing request sees.
  test "rejecting a proposal another request already approved changes nothing" do
    proposal = propose(asset_class: "equity", asset_sub_class: "stock")

    # Another request wins the race and approves it.
    Security::ClassificationProposal.where(id: proposal.id).update_all(status: "approved")

    assert_not proposal.reject!, "the stale request must not be told it rejected anything"
    assert_equal "approved", proposal.reload.status,
                 "a rejection overwrote a status set by a request that had already finished"
  end

  test "approving a proposal another request already rejected changes nothing" do
    proposal = propose(asset_class: "equity", asset_sub_class: "stock")

    Security::ClassificationProposal.where(id: proposal.id).update_all(status: "rejected")

    assert_not proposal.approve!, "the stale request must not be told it approved anything"
    assert_equal "rejected", proposal.reload.status
    assert_nil @security.reload.asset_class,
               "the security was written by an approve that lost the race"
  end

  test "approving writes the security and records the source as ai" do
    proposal = propose(
      asset_class: "equity", asset_sub_class: "stock",
      sector: "Technology", region: "north_america"
    )

    assert proposal.approve!

    @security.reload
    assert_equal "equity", @security.asset_class
    assert_equal "stock", @security.asset_sub_class
    assert_equal "Technology", @security.sector
    assert_equal "north_america", @security.region
    assert_equal "ai", @security.classification_source
    assert proposal.reload.approved?
  end

  # End to end with provider classification ingestion: the next sync must not
  # silently undo an approval. The provider is really asked, and its answer
  # really lands where the approval said nothing (industry), so the approved
  # columns surviving is precedence at work, not a skipped refresh.
  test "an approved classification survives a provider refresh that disagrees" do
    # Approval saves the security, and a configured Brandfetch would fetch a
    # logo in that save, which this test is not about.
    Setting.stubs(:brand_fetch_client_id).returns(nil)
    propose(asset_class: "fixed_income", asset_sub_class: "bond", sector: "Technology").approve!

    provider = capable_provider
    provider.stubs(:class).returns(Provider::TwelveData)
    provider.expects(:fetch_security_info).once.returns(provider_success_response(
      Provider::SecurityConcept::SecurityInfo.new(
        symbol: "AAPL", name: nil, links: nil, logo_url: nil, description: nil,
        kind: "Common Stock", exchange_operating_mic: "XNAS",
        sector: "Provider sector", industry: "Consumer Electronics"
      )
    ))
    @security.reload.stubs(:price_data_provider).returns(provider)
    assert_nil @security.industry

    @security.import_provider_details(include_classification: true)

    @security.reload
    assert_equal "Consumer Electronics", @security.industry, "the provider's answer never landed"
    assert_equal [ "fixed_income", "bond", "Technology", "ai" ],
                 [ @security.asset_class, @security.asset_sub_class, @security.sector, @security.classification_source ],
                 "a provider refresh overwrote an approved classification"
  end

  # The window between proposing and approving is exactly where the security's
  # state can change, so the lock is re-checked at approval rather than trusted
  # from validation time.
  test "a security locked after the proposal was made is not approved over" do
    proposal = propose(asset_class: "equity", asset_sub_class: "stock")

    @security.update_columns(
      asset_class: "fixed_income", asset_sub_class: "bond",
      classification_source: "manual", classification_locked: true
    )

    assert_not proposal.approve!
    assert_equal "fixed_income", @security.reload.asset_class,
                 "an approval overwrote a classification locked after the proposal"
    assert proposal.reload.pending?, "a refused approval should not be marked approved"
  end

  # The two halves of the veto, each on its own. The test above sets both at
  # once, so it passes while either half is missing.
  test "a lock alone, applied after the proposal, refuses the approval" do
    proposal = propose(asset_class: "equity", asset_sub_class: "stock")

    @security.update_columns(
      asset_class: "fixed_income", asset_sub_class: "bond",
      classification_source: "provider", classification_locked: true
    )

    assert_not proposal.approve!
    assert_equal %w[fixed_income bond provider],
                 @security.reload.values_at(:asset_class, :asset_sub_class, :classification_source)
    assert proposal.reload.pending?
  end

  test "a hand classification alone, made after the proposal, refuses the approval" do
    proposal = propose(asset_class: "equity", asset_sub_class: "stock")

    @security.update_columns(
      asset_class: "fixed_income", asset_sub_class: "bond",
      classification_source: "manual", classification_locked: false
    )

    assert_not proposal.approve!
    assert_equal %w[fixed_income bond manual],
                 @security.reload.values_at(:asset_class, :asset_sub_class, :classification_source)
    assert proposal.reload.pending?
  end

  # The security must already hold the columns this proposal leaves alone, or the
  # test proves nothing: asserting `asset_class` is nil when it was nil anyway
  # passes whether or not the blank values are stripped.
  test "a proposal that only answers the region does not blank the columns it left alone" do
    @security.update!(
      asset_class: "equity", asset_sub_class: "stock",
      sector: "Technology", classification_source: "provider"
    )

    propose(region: "europe").approve!

    @security.reload
    assert_equal "europe", @security.region
    assert_equal "equity", @security.asset_class, "a column the proposal did not answer was blanked"
    assert_equal "stock", @security.asset_sub_class
    assert_equal "Technology", @security.sector
    # NOT "ai". `classification_source` names who set the ASSET classification,
    # and this proposal did not set one -- the provider's asset columns are
    # untouched above. Claiming the source here would also shut a provider
    # out of those columns for good, since "ai" outranks "provider" in the
    # precedence order.
    assert_equal "provider", @security.classification_source,
                 "a region-only approval claimed an asset classification it did not make"
  end

  # The same rule from the other side, so the fix cannot be "never stamp ai":
  # a proposal that DOES answer the asset class claims the classification.
  test "a proposal that answers the asset class claims the classification" do
    propose(asset_class: "equity", asset_sub_class: "stock").approve!

    @security.reload
    assert_equal "equity", @security.asset_class
    assert_equal "ai", @security.classification_source
  end

  # And a security nothing has classified stays unclaimed when the proposal
  # only answers a region, so a provider can still fill the asset columns.
  test "a region-only approval leaves an unclassified security open to a provider" do
    propose(region: "europe").approve!

    @security.reload
    assert_equal "europe", @security.region
    assert_nil @security.classification_source,
               "the provider was locked out of the asset columns by a region"
  end

  # `compact_blank` dropped a blank sub-class while keeping the class beside
  # it, so re-classifying left the OLD sub-class under the NEW class. The model
  # validates the two columns independently, so nothing rejects the pair.
  # Asserts the delta: the security starts with a full,
  # valid pair, and the proposal answers only the class.
  test "a proposal that changes the asset class clears a sub-class it does not answer" do
    @security.update!(
      asset_class: "equity", asset_sub_class: "stock", classification_source: "provider"
    )

    propose(asset_class: "fixed_income", asset_sub_class: nil).approve!

    @security.reload
    assert_equal "fixed_income", @security.asset_class
    assert_nil @security.asset_sub_class,
               "stock survived a move to fixed_income, a pair nothing validates"
  end

  # The other side, so the fix is not "always clear the sub-class": a proposal
  # that answers both writes both.
  test "a proposal that answers both asset columns writes both" do
    @security.update!(asset_class: "equity", asset_sub_class: "stock")

    propose(asset_class: "fixed_income", asset_sub_class: "bond").approve!

    @security.reload
    assert_equal %w[fixed_income bond], @security.values_at(:asset_class, :asset_sub_class)
  end

  # And a proposal that answers neither leaves the pair entirely alone.
  test "a region-only proposal leaves both asset columns untouched" do
    @security.update!(asset_class: "equity", asset_sub_class: "stock")

    propose(asset_class: nil, asset_sub_class: nil, region: "europe").approve!

    @security.reload
    assert_equal %w[equity stock], @security.values_at(:asset_class, :asset_sub_class)
    assert_equal "europe", @security.region
  end

  # -------------------------------------------------------------- rejecting

  # An unconditional rejection would let a stale reject form from another tab
  # move an already-approved proposal to `rejected` while the security stays
  # "ai" -- the row would then deny a classification that is still in force.
  test "answering only the class a fund already has keeps its sub-class" do
    @security.update!(asset_class: "equity", asset_sub_class: "etf", classification_source: "provider")

    assert propose(asset_class: "equity", sector: "Technology").approve!

    assert_equal "etf", @security.reload.asset_sub_class
  end

  test "a fund approved without a region loses the region its listing implies" do
    @security.update_columns(country_code: "IE", region: "europe")

    assert propose(asset_class: "equity", asset_sub_class: "etf").approve!

    assert_nil @security.reload.region
  end

  test "a fund approved without a region keeps a region someone set by hand" do
    @security.update_columns(country_code: "IE", region: "north_america")

    assert propose(asset_class: "equity", asset_sub_class: "etf").approve!

    assert_equal "north_america", @security.reload.region
  end

  test "a provider classification written after the proposal is not approved over" do
    proposal = propose(asset_class: "equity", asset_sub_class: "stock")
    @security.update_columns(asset_class: "fixed_income", asset_sub_class: "bond", classification_source: "provider",
                             classification_fetched_at: 1.minute.from_now)

    assert_not proposal.approve!
    assert_equal "fixed_income", @security.reload.asset_class
    assert proposal.reload.pending?
  end

  test "an approval the security cannot store is refused and logged, not raised" do
    proposal = propose(asset_class: "equity", asset_sub_class: "stock")
    @security.update_columns(price_provider: "no_such_provider")

    assert_difference -> { DebugLogEntry.where(message: "Classification proposal could not be approved").count }, 1 do
      assert_not proposal.approve!
    end
    assert proposal.reload.pending?
  end

  test "rejecting an already-approved proposal is refused" do
    proposal = propose(asset_class: "equity", asset_sub_class: "stock")
    proposal.approve!

    assert_not proposal.reject!
    assert proposal.reload.approved?, "an approved proposal was moved back to rejected"
    assert_equal "ai", @security.reload.classification_source
  end

  # The security is classified differently from the proposal first, so a
  # `reject!` that wrote the proposal's answer would show up as a change.
  test "rejecting leaves the security untouched" do
    proposal = propose(asset_class: "equity", asset_sub_class: "stock", sector: "Technology", region: "europe")
    @security.update!(asset_class: "fixed_income", asset_sub_class: nil, sector: "Utilities",
                      region: "north_america", classification_source: "provider")
    before = @security.reload.attributes.slice(*%w[asset_class asset_sub_class sector region classification_source classification_locked])

    assert proposal.reject!

    assert proposal.reload.rejected?
    assert_equal before, @security.reload.attributes.slice(*before.keys)
  end

  # A hand classification after the proposal stops it being approved, and must
  # not stop the person clearing it out of the queue either.
  test "a proposal can still be rejected after the security is classified by hand" do
    proposal = propose(asset_class: "equity")
    @security.update!(asset_class: "fixed_income", classification_source: "manual")

    assert proposal.reject!
    assert proposal.reload.rejected?
  end

  # ------------------------------------------------- validation and re-proposals

  # `proposed_attributes` writes a sub-class only beside a class, so a
  # sub-class alone was valid, approvable, marked approved and wrote nothing.
  test "a sub-class without an asset class is refused" do
    proposal = Security::ClassificationProposal.new(security: @security, family: @family, asset_sub_class: "etf")

    assert_not proposal.valid?
    assert_includes proposal.errors[:asset_sub_class], "needs an asset class beside it"
  end

  test "an approval never reports success while writing no classification column" do
    columns = %w[asset_class asset_sub_class sector region classification_source]
    [ { asset_class: "equity" }, { sector: "Technology" }, { region: "europe" },
      { asset_class: "equity", asset_sub_class: "stock" } ].each do |answer|
      Security::ClassificationProposal.delete_all
      @security.update_columns(asset_class: nil, asset_sub_class: nil, sector: nil, region: nil,
                               classification_source: nil, classification_locked: false)
      before = @security.reload.attributes.slice(*columns)

      assert propose(**answer).approve!, "#{answer} was not approved"
      assert_not_equal before, @security.reload.attributes.slice(*columns), "#{answer} approved as a no-op"
    end
  end

  # Replacing means the second proposal is the whole answer, not a patch on
  # the first: otherwise a region-only proposer approves someone else's asset
  # class, stamped "ai".
  test "re-proposing fewer fields clears the ones the new proposal left out" do
    propose(asset_class: "equity", asset_sub_class: "stock", sector: "Technology", rationale: "First")
    propose(region: "europe")

    proposal = Security::ClassificationProposal.sole
    assert_equal "europe", proposal.region
    assert_nil proposal.asset_class
    assert_nil proposal.asset_sub_class
    assert_nil proposal.sector
    assert_nil proposal.rationale
  end

  test "re-proposing after the security is classified by hand is refused, and the stored row is unchanged" do
    first = propose(asset_class: "equity")
    @security.update!(asset_class: "fixed_income", classification_source: "manual")

    assert_raises(ActiveRecord::RecordInvalid) { propose(asset_class: "commodity") }

    stored = first.reload
    assert stored.pending?
    assert_equal "equity", stored.asset_class
  end

  test "re-proposing after the security is locked is refused" do
    propose(asset_class: "equity")
    @security.update!(classification_locked: true)

    assert_raises(ActiveRecord::RecordInvalid) { propose(asset_class: "commodity") }
    assert_equal "equity", Security::ClassificationProposal.sole.asset_class
  end

  test "an over-long sector or rationale is refused, and the longest allowed is kept" do
    { sector: 255, rationale: 2000 }.each do |field, limit|
      too_long = Security::ClassificationProposal.new(security: @security, family: @family, asset_class: "equity", field => "x" * (limit + 1))
      assert_not too_long.valid?, "#{field} accepted #{limit + 1} characters"
      assert too_long.errors[field].any?

      longest = Security::ClassificationProposal.new(security: @security, family: @family, asset_class: "equity", field => "x" * limit)
      assert longest.valid?, "#{field} refused #{limit} characters"
    end
  end

  # Two first proposals for one pair: both miss `find_by`, and the loser's
  # INSERT hits the unique index.
  test "a first proposal that loses the insert race updates the winner's row instead" do
    winner = propose(asset_class: "equity")
    Security::ClassificationProposal.stubs(:find_by).returns(nil).then.returns(winner)

    assert_no_difference "Security::ClassificationProposal.count" do
      Security::ClassificationProposal.propose!(security: @security, family: @family, asset_class: "commodity")
    end
    assert_equal "commodity", winner.reload.asset_class
  end

  # A caller that read the security before a provider classified it must not
  # record a proposal: the check runs again under the security's lock.
  test "proposing only while open refuses a security classified since the caller read it" do
    stale = Security.find(@security.id)
    @security.update_columns(asset_class: "equity", asset_sub_class: "stock", classification_source: "provider")

    assert_nil Security::ClassificationProposal.propose!(
      security: stale, family: @family, open_sources: [ nil, "default" ], asset_class: "fixed_income"
    )
    assert_not Security::ClassificationProposal.exists?(security: @security, family: @family)
  end

  test "proposing only while open still records an unclassified security" do
    proposal = Security::ClassificationProposal.propose!(
      security: @security, family: @family, open_sources: [ nil, "default" ], asset_class: "equity"
    )

    assert proposal&.pending?
  end

  private
    def propose(**attrs)
      Security::ClassificationProposal.propose!(
        security: @security, family: @family, **attrs
      )
    end
end
