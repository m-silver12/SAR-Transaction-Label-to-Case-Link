# SAR transaction label to case link

Shareable Snowflake models for linking historical AML transaction-label values to
canonical money movements and temporally eligible investigation cases.

## Model flow

1. `models/01_sar_label_intervals.sql` reconstructs one row per period in which a
   label value was active. It treats a label-changing `UPDATE` as the end of the
   previous value and the start of the new value, while retaining the original
   lifecycle timestamp used by the 90-day SAR-value rule.
2. `models/02_sar_label_investigation_base.sql` maps transfer, card and direct-debit
   entity IDs to `money_movement_id`, takes the transaction owner from
   `MONEY_MOVEMENT_CORE.profile_id`, and links cases using a half-open interval:
   `case_link_timestamp >= active_from and case_link_timestamp < active_to`.
3. `models/03_sar_action_fact.sql` produces one row per `money_movement_id` for the
   SAR-value numerator, preventing transaction value from being counted once per
   label or case.
4. `analysis/compare_mature_sar_value.sql` compares the action fact with
   `RISK_SAR_VALUE_RATE_KRI_AGGREGATION` for the mature window used in the August
   2026 validation: `[2025-01-01, 2026-05-03)`.

## Important semantics

- A transaction-to-case link means that the case belongs to the transaction owner
  and its link timestamp falls while the label value was active. It does not prove
  the investigator explicitly selected that individual transaction.
- `TRANSFER.entity_id` maps to `REPORT_ACTION_STEP.request_id`.
- `CARD_TRANSACTION.entity_id` maps to
  `REPORT_ACTION_STEP.plastic_transaction_id`.
- `DIRECT_DEBIT_TRANSACTION.entity_id` maps through
  `BORDERLESS_DD.TRANSACTION.balance_transaction_id`.
- The investigation base includes case attributes rather than forcing an external-
  report filter. Use `is_externally_reported = true` to reproduce the original
  label-to-reported-case population. The action fact uses
  `subject_alert_type_enhanced is not null` to match the governed SAR-value
  numerator population.
- Replace `SANDBOX_DB.LIMITED_SANDBOX_FINCRIME_ANALYTICS` if a different output
  schema is required.

These are Snowflake SQL scripts, not dbt models. Run them in numeric order.
