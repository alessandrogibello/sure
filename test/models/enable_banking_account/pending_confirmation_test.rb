require "test_helper"

class EnableBankingAccount::PendingConfirmationTest < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)

    @enable_banking_item = EnableBankingItem.create!(
      family: @family,
      name: "Test EB Pending",
      country_code: "LT",
      application_id: "test_app_id",
      client_certificate: "test_cert",
      session_id: "test_session",
      session_expires_at: 1.day.from_now
    )
    @enable_banking_account = EnableBankingAccount.create!(
      enable_banking_item: @enable_banking_item,
      name: "Revolut Account",
      uid: "hash_revolut_abc",
      account_id: "uuid-revolut-1234",
      currency: "EUR"
    )
    AccountProvider.create!(account: @account, provider: @enable_banking_account)
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  def create_pending_entry(date:, amount: 10.0, name: "Pending TX")
    entry = @account.entries.create!(
      name: name,
      date: date,
      amount: amount,
      currency: "EUR",
      source: "enable_banking",
      entryable: Transaction.new(
        extra: { "enable_banking" => { "pending" => true } }
      )
    )
    entry
  end

  def create_posted_entry(date:, amount: 10.0, name: "Posted TX")
    @account.entries.create!(
      name: name,
      date: date,
      amount: amount,
      currency: "EUR",
      source: "enable_banking",
      entryable: Transaction.new(extra: {})
    )
  end

  # ── Tests ─────────────────────────────────────────────────────────────────────

  test "confirms a stale pending transaction older than threshold" do
    old_entry = create_pending_entry(date: 4.days.ago.to_date)

    confirmed = @enable_banking_account.confirm_stale_pending_transactions!

    assert_equal 1, confirmed
    old_entry.reload
    refute old_entry.transaction.pending?, "Transaction should no longer be pending after confirmation"
    assert_nil old_entry.transaction.extra&.dig("enable_banking", "pending"),
               "pending key should be removed from extra"
  end

  test "does not confirm a pending transaction within the threshold window" do
    recent_entry = create_pending_entry(date: 1.day.ago.to_date)

    confirmed = @enable_banking_account.confirm_stale_pending_transactions!

    assert_equal 0, confirmed
    recent_entry.reload
    assert recent_entry.transaction.pending?, "Recent pending transaction should remain pending"
  end

  test "does not confirm a pending transaction exactly on the boundary date" do
    # Cutoff is strictly < threshold_days.ago.to_date, so boundary date (2 days ago) is still pending
    boundary_entry = create_pending_entry(
      date: EnableBankingAccount::PendingConfirmation::PENDING_CONFIRMATION_DAYS.days.ago.to_date
    )

    confirmed = @enable_banking_account.confirm_stale_pending_transactions!

    assert_equal 0, confirmed
    boundary_entry.reload
    assert boundary_entry.transaction.pending?
  end

  test "does not touch non-pending transactions" do
    posted_entry = create_posted_entry(date: 5.days.ago.to_date)

    confirmed = @enable_banking_account.confirm_stale_pending_transactions!

    assert_equal 0, confirmed
    posted_entry.reload
    refute posted_entry.transaction.pending?
  end

  test "does not touch pending transactions from other providers" do
    simplefin_entry = @account.entries.create!(
      name: "SimpleFIN Pending",
      date: 5.days.ago.to_date,
      amount: 25.0,
      currency: "EUR",
      source: "simplefin",
      entryable: Transaction.new(
        extra: { "simplefin" => { "pending" => true } }
      )
    )

    confirmed = @enable_banking_account.confirm_stale_pending_transactions!

    assert_equal 0, confirmed
    simplefin_entry.reload
    assert simplefin_entry.transaction.pending?
  end

  test "confirms multiple stale pending transactions in one call" do
    entry1 = create_pending_entry(date: 5.days.ago.to_date, name: "Old Pending 1")
    entry2 = create_pending_entry(date: 6.days.ago.to_date, name: "Old Pending 2")
    recent = create_pending_entry(date: 1.day.ago.to_date, name: "Recent Pending")

    confirmed = @enable_banking_account.confirm_stale_pending_transactions!

    assert_equal 2, confirmed
    entry1.reload
    entry2.reload
    recent.reload
    refute entry1.transaction.pending?
    refute entry2.transaction.pending?
    assert recent.transaction.pending?
  end

  test "returns 0 when account has no linked account" do
    # Create an unlinked EB account (no AccountProvider)
    unlinked = EnableBankingAccount.create!(
      enable_banking_item: @enable_banking_item,
      name: "Unlinked",
      uid: "hash_unlinked",
      account_id: "uuid-unlinked",
      currency: "EUR"
    )

    confirmed = unlinked.confirm_stale_pending_transactions!

    assert_equal 0, confirmed
  end

  test "respects custom threshold_days parameter" do
    # With threshold_days: 10, a 5-day-old pending is NOT stale yet
    entry = create_pending_entry(date: 5.days.ago.to_date)

    confirmed = @enable_banking_account.confirm_stale_pending_transactions!(threshold_days: 10)

    assert_equal 0, confirmed
    entry.reload
    assert entry.transaction.pending?
  end

  test "extra hash is cleaned up when enable_banking namespace becomes empty after confirmation" do
    entry = @account.entries.create!(
      name: "Minimal Pending",
      date: 5.days.ago.to_date,
      amount: 5.0,
      currency: "EUR",
      source: "enable_banking",
      entryable: Transaction.new(
        extra: { "enable_banking" => { "pending" => true } }
      )
    )

    @enable_banking_account.confirm_stale_pending_transactions!

    entry.reload
    # The enable_banking namespace should be removed when empty
    assert_nil entry.transaction.extra&.dig("enable_banking")
  end

  test "extra hash retains other enable_banking fields after confirmation" do
    entry = @account.entries.create!(
      name: "Pending with FX",
      date: 5.days.ago.to_date,
      amount: 20.0,
      currency: "USD",
      source: "enable_banking",
      entryable: Transaction.new(
        extra: { "enable_banking" => { "pending" => true, "fx_rate" => "1.08" } }
      )
    )

    @enable_banking_account.confirm_stale_pending_transactions!

    entry.reload
    assert_equal "1.08", entry.transaction.extra&.dig("enable_banking", "fx_rate"),
                 "Other enable_banking fields must be preserved"
    assert_nil entry.transaction.extra&.dig("enable_banking", "pending"),
               "Only the pending flag should be removed"
  end
end
