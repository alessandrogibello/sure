# Mixin for EnableBankingAccount that auto-confirms pending transactions
# that have exceeded the bank's expected settlement window.
#
# Background: Enable Banking fetches PDNG (pending) and BOOK (booked) transactions
# separately. When `syncs_include_pending` is enabled, pending transactions are stored
# with `extra["enable_banking"]["pending"] = true`. Normally the importer removes stale
# pending entries when the corresponding BOOK transaction arrives. However, some banks
# (e.g. Revolut) silently settle pending transactions without re-emitting them in the
# BOOK feed. This module provides a fallback: any pending transaction older than
# PENDING_CONFIRMATION_DAYS is assumed settled and its pending flag is cleared.
module EnableBankingAccount::PendingConfirmation
  # Number of days after which a pending Enable Banking transaction is auto-confirmed.
  # This is a FALLBACK safety net — the primary mechanism is the C5 "absent from
  # PDNG feed" detection in the importer, which confirms on the same sync cycle.
  # This age-based fallback only fires when syncs have been failing and C5 never ran.
  #
  # PSD2 banks must settle pending authorisations within 1 business day.
  # 2 calendar days covers weekends (Friday evening → Sunday) with margin.
  PENDING_CONFIRMATION_DAYS = 1

  extend ActiveSupport::Concern

  included do
    # No additional associations or validations needed — operates on existing entries.
  end

  # Confirms all stale pending Enable Banking transactions for this account.
  #
  # A transaction is "stale pending" if:
  #   - It belongs to this account
  #   - Its `extra["enable_banking"]["pending"]` is true
  #   - Its date is older than PENDING_CONFIRMATION_DAYS days ago
  #
  # Confirmation means removing the `pending` key from `extra["enable_banking"]`
  # so that downstream queries (e.g. `Transaction.pending`, `Transaction#pending?`)
  # no longer treat it as pending.
  #
  # @param threshold_days [Integer] Override for the staleness window (default: PENDING_CONFIRMATION_DAYS)
  # @return [Integer] number of transactions confirmed
  def confirm_stale_pending_transactions!(threshold_days: PENDING_CONFIRMATION_DAYS)
    return 0 unless current_account.present?

    cutoff_date = threshold_days.days.ago.to_date

    stale_pending_entries = current_account.entries
      .joins("INNER JOIN transactions ON transactions.id = entries.entryable_id AND entries.entryable_type = 'Transaction'")
      .where(source: "enable_banking")
      .where("entries.date < ?", cutoff_date)
      .where("(transactions.extra -> 'enable_banking' ->> 'pending')::boolean = true")

    confirmed_count = 0

    stale_pending_entries.each do |entry|
      transaction = entry.entryable
      next unless transaction.is_a?(Transaction)

      updated_extra = (transaction.extra || {}).deep_dup
      eb_extra = updated_extra["enable_banking"] || {}
      eb_extra.delete("pending")
      updated_extra["enable_banking"] = eb_extra
      updated_extra.delete("enable_banking") if eb_extra.empty?

      begin
        transaction.update_columns(extra: updated_extra)
        confirmed_count += 1
        Rails.logger.info(
          "EnableBankingAccount::PendingConfirmation - Confirmed stale pending transaction " \
          "entry=#{entry.id} date=#{entry.date} account=#{current_account.id}"
        )
      rescue => e
        Rails.logger.error(
          "EnableBankingAccount::PendingConfirmation - Failed to confirm stale pending transaction " \
          "entry=#{entry.id}: #{e.message}"
        )
      end
    end

    confirmed_count
  end
end
