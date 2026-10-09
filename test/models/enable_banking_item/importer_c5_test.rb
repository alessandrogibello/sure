require "test_helper"

class EnableBankingItem::ImporterC5Test < ActiveSupport::TestCase
  setup do
    @family = families(:dylan_family)
    @account = accounts(:depository)

    @enable_banking_item = EnableBankingItem.create!(
      family: @family,
      name: "Test EB C5",
      country_code: "LT",
      application_id: "test_app_id",
      client_certificate: "test_cert",
      session_id: "test_session",
      session_expires_at: 1.day.from_now,
      sync_start_date: Date.new(2026, 3, 1)
    )
    @enable_banking_account = EnableBankingAccount.create!(
      enable_banking_item: @enable_banking_item,
      name: "Revolut EUR",
      uid: "hash_rev_eur",
      account_id: "uuid-rev-eur",
      currency: "EUR"
    )
    AccountProvider.create!(account: @account, provider: @enable_banking_account)

    @mock_provider = mock()
    @importer = EnableBankingItem::Importer.new(@enable_banking_item, enable_banking_provider: @mock_provider)
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  def build_stored_pending(entry_ref:, tx_id: nil)
    tx = {
      "entry_reference" => entry_ref,
      "booking_date" => Date.current.to_s,
      "transaction_amount" => { "amount" => "10.00", "currency" => "EUR" },
      "credit_debit_indicator" => "DBIT",
      "status" => "PDNG",
      "_pending" => true
    }
    tx["transaction_id"] = tx_id if tx_id
    tx
  end

  def build_stored_booked(entry_ref:, tx_id: nil)
    tx = {
      "entry_reference" => entry_ref,
      "booking_date" => Date.current.to_s,
      "transaction_amount" => { "amount" => "10.00", "currency" => "EUR" },
      "credit_debit_indicator" => "DBIT",
      "status" => "BOOK"
    }
    tx["transaction_id"] = tx_id if tx_id
    tx
  end

  # ── C5: confirm_silently_settled_pending ─────────────────────────────────────

  test "confirms pending entry that vanished from PDNG feed and is not in BOOK" do
    stored = [ build_stored_pending(entry_ref: "settled_ref") ]

    result = @importer.send(
      :confirm_silently_settled_pending,
      @enable_banking_account, stored,
      current_pdng_ids: Set.new,        # empty — tx vanished from PDNG
      current_book_ids: Set.new,        # not in BOOK either
      current_book_entry_refs: Set.new
    )

    assert result, "should return true when entries were confirmed"
    refute stored.first["_pending"], "_pending flag should be removed"
    refute stored.first.key?("_pending"), "_pending key should be deleted"
  end

  test "skips pending entry still present in current PDNG feed" do
    stored = [ build_stored_pending(entry_ref: "still_pending_ref") ]

    result = @importer.send(
      :confirm_silently_settled_pending,
      @enable_banking_account, stored,
      current_pdng_ids: Set["still_pending_ref"],
      current_book_ids: Set.new,
      current_book_entry_refs: Set.new
    )

    refute result, "should return false — nothing confirmed"
    assert stored.first["_pending"], "pending flag should remain"
  end

  test "skips pending entry that appeared in BOOK feed (C4 handles it)" do
    stored = [ build_stored_pending(entry_ref: "booked_ref", tx_id: "txn_123") ]

    result = @importer.send(
      :confirm_silently_settled_pending,
      @enable_banking_account, stored,
      current_pdng_ids: Set.new,
      current_book_ids: Set["txn_123"],
      current_book_entry_refs: Set.new
    )

    refute result
    assert stored.first["_pending"]
  end

  test "skips pending entry matched by entry_reference in BOOK (no tx_id)" do
    stored = [ build_stored_pending(entry_ref: "booked_by_ref") ]

    result = @importer.send(
      :confirm_silently_settled_pending,
      @enable_banking_account, stored,
      current_pdng_ids: Set.new,
      current_book_ids: Set.new,
      current_book_entry_refs: Set["booked_by_ref"]
    )

    refute result
    assert stored.first["_pending"]
  end

  test "does not touch non-pending stored entries" do
    stored = [ build_stored_booked(entry_ref: "booked_ref") ]

    result = @importer.send(
      :confirm_silently_settled_pending,
      @enable_banking_account, stored,
      current_pdng_ids: Set.new,
      current_book_ids: Set.new,
      current_book_entry_refs: Set.new
    )

    refute result
    refute stored.first.key?("_pending")
  end

  test "confirms multiple silently settled entries in one pass" do
    stored = [
      build_stored_pending(entry_ref: "settled_1"),
      build_stored_pending(entry_ref: "still_pending"),
      build_stored_pending(entry_ref: "settled_2")
    ]

    result = @importer.send(
      :confirm_silently_settled_pending,
      @enable_banking_account, stored,
      current_pdng_ids: Set["still_pending"],
      current_book_ids: Set.new,
      current_book_entry_refs: Set.new
    )

    assert result
    refute stored[0].key?("_pending"), "settled_1 should be confirmed"
    assert stored[1]["_pending"],       "still_pending should remain"
    refute stored[2].key?("_pending"), "settled_2 should be confirmed"
  end

  test "strips nested extra.enable_banking.pending from stored hash" do
    stored = [ {
      "entry_reference" => "nested_ref",
      "booking_date" => Date.current.to_s,
      "transaction_amount" => { "amount" => "10.00", "currency" => "EUR" },
      "credit_debit_indicator" => "DBIT",
      "status" => "PDNG",
      "_pending" => true,
      "extra" => { "enable_banking" => { "pending" => true, "fx_rate" => "1.08" } }
    } ]

    @importer.send(
      :confirm_silently_settled_pending,
      @enable_banking_account, stored,
      current_pdng_ids: Set.new,
      current_book_ids: Set.new,
      current_book_entry_refs: Set.new
    )

    assert_nil stored.first.dig("extra", "enable_banking", "pending"),
               "pending should be removed from nested extra"
    assert_equal "1.08", stored.first.dig("extra", "enable_banking", "fx_rate"),
                 "other extra fields should be preserved"
  end

  # ── C5: confirm_db_pending_entries ───────────────────────────────────────────

  test "clears pending flag on DB Transaction records for confirmed entries" do
    entry = @account.entries.create!(
      name: "Silently Settled",
      date: Date.current,
      amount: 10.0,
      currency: "EUR",
      source: "enable_banking",
      external_id: "enable_banking_settled_ref",
      entryable: Transaction.new(
        extra: { "enable_banking" => { "pending" => true } }
      )
    )

    @importer.send(
      :confirm_db_pending_entries,
      @enable_banking_account,
      [ "enable_banking_settled_ref" ]
    )

    entry.reload
    refute entry.transaction.pending?, "Transaction should no longer be pending"
    assert_nil entry.transaction.extra&.dig("enable_banking", "pending")
  end

  test "preserves other extra fields when clearing DB pending flag" do
    entry = @account.entries.create!(
      name: "Settled with FX",
      date: Date.current,
      amount: 20.0,
      currency: "EUR",
      source: "enable_banking",
      external_id: "enable_banking_fx_ref",
      entryable: Transaction.new(
        extra: { "enable_banking" => { "pending" => true, "fx_rate" => "1.12" } }
      )
    )

    @importer.send(
      :confirm_db_pending_entries,
      @enable_banking_account,
      [ "enable_banking_fx_ref" ]
    )

    entry.reload
    assert_equal "1.12", entry.transaction.extra&.dig("enable_banking", "fx_rate")
    assert_nil entry.transaction.extra&.dig("enable_banking", "pending")
  end

  test "does not crash when no matching DB entries exist" do
    assert_nothing_raised do
      @importer.send(
        :confirm_db_pending_entries,
        @enable_banking_account,
        [ "enable_banking_nonexistent" ]
      )
    end
  end
end
