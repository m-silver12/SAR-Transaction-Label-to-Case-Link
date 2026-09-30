# SAR transaction label to case link

Models for linking historical AML transaction-label values to
money movements and eligible investigation cases.

## Model flow

1. `models/01_sar_label_intervals.sql` reconstructs one row per period in which a
   label value was active. An UPDATE ends the previous label value and starts the
   updated value, but the 90-day SAR-value calculation continues to use the original
   label insertion date.
2. `models/02_sar_label_investigation_base.sql` maps transfer, card and direct-debit
   entity IDs to `money_movement_id`, takes the transaction owner from
   `MONEY_MOVEMENT_CORE.profile_id`, and links cases using a active interval.
3. `models/03_sar_action_fact.sql` produces one row per `money_movement_id` for the
   SAR-value numerator, preventing transaction value from being counted once per
   label or case.
4. `analysis/compare_mature_sar_value.sql` compares the action fact with
   `RISK_SAR_VALUE_RATE_KRI_AGGREGATION` for the mature window used in the August
   2026 validation: `[2025-01-01, 2026-05-03)`.

## Strict reconstruction and direct case attribution

`models/04_strict_label_reconstruction_case_attribution_sample.sql` is a
separate evidence-layer prototype. It strengthens the original interval
reconstruction before that evidence is used to build a replacement action fact.

The sandbox version is intentionally a deterministic 1/64 sample of
transaction-label scopes observed in September 2026. It reads the complete
available event history for those selected scopes, so reconstructed intervals
are not truncated to September. The sampled output is materialized as
`SANDBOX_DB.LIMITED_SANDBOX_FINCRIME_ANALYTICS.SAR_LABEL_RECONSTRUCTION_CASE_ATTRIBUTION_SAMPLE`.
The full supported source currently contains roughly 243 million events, so a
full-history version needs an incremental or staged production design rather
than this proof-of-concept CTAS.

The September sample build produced 285,859 interval/unresolved rows across
273,877 lifecycle keys. The validation query found no duplicate non-null
interval keys and no lifecycle with more than one currently active interval.
Run `analysis/validate_strict_label_reconstruction_case_attribution_sample.sql`
after rebuilding the sample.

The model:

- distinguishes safely reconstructed histories from ambiguous ones;
- supports simultaneous labels when there are no UPDATE events;
- retains UPDATE-first histories as left-censored rather than presenting the
  first observed UPDATE as the original creation time;
- recovers the current immutable `FINCRIME_LABELS.ID` where possible;
- adds retained `AML_RISK.FINCRIME_LABEL` case associations without fanning out
  the interval grain; and
- identifies a candidate origin case only when exactly one retained direct case
  association was created on the observed INSERT date.

The reconstruction statuses are:

| Status | Meaning |
| --- | --- |
| `EXACT_SINGLE_ACTIVE_LABEL` | The event stream has at most one active label and can be reconstructed deterministically. |
| `EXACT_PARALLEL_NO_UPDATE` | Multiple labels coexist, but INSERT and DELETE events can be paired by label value. |
| `LEFT_CENSORED_UPDATE_START` | The history begins with UPDATE; the first observed UPDATE is an observed start, not proven creation. |
| `AMBIGUOUS_PARALLEL_UPDATE` | An UPDATE occurs while several labels coexist and the log does not identify which immutable label changed. |
| `INCOMPLETE_HISTORY` | The available events do not provide a defensible interval history. |

This model does not yet apply the 90-day SAR-value rule, map raw label entities
to `money_movement_id`, or select a canonical reporting case. Those should be
applied downstream after the reporting timestamp contract is agreed. Current
label state is retained for audit; historical eligibility should use the label
value active interval at the agreed reporting timestamp.

## Important notes

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

These are Snowflake SQL scripts, not dbt models. Run them in numeric order.
