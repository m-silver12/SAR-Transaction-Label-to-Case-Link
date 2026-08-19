-- Grain: one row per money_movement_id.
-- This is the SAR-value numerator fact and must not fan out by label or case.

create or replace table
    sandbox_db.limited_sandbox_fincrime_analytics.sar_action_fact as
with eligible_rows as (
    select
        sar_label_investigation_base.money_movement_id,
        sar_label_investigation_base.transaction_profile_id,
        sar_label_investigation_base.action_completed_at_timestamp,
        sar_label_investigation_base.action_amount_gbp
    from sandbox_db.limited_sandbox_fincrime_analytics.sar_label_investigation_base
        as sar_label_investigation_base
    where sar_label_investigation_base.included_in_90d_sar_value = true
        and sar_label_investigation_base.subject_alert_type_enhanced is not null
),
final as (
    select
        eligible_rows.money_movement_id,
        max(eligible_rows.transaction_profile_id) as transaction_profile_id,
        max(eligible_rows.action_completed_at_timestamp)
            as action_completed_at_timestamp,
        max(eligible_rows.action_amount_gbp) as action_amount_gbp,
        count(*) as supporting_label_case_row_count
    from eligible_rows
    group by eligible_rows.money_movement_id
)
select * from final
;
