-- Mature comparison as at 2026-08-01.
-- 2026-05-03 00:00 is the exclusive cutoff 90 days before 2026-08-01.

with current_actions as (
    select
        risk_sar_value_rate_kri_aggregation.money_movement_id::string
            as money_movement_id,
        max(risk_sar_value_rate_kri_aggregation.action_amount_gbp)
            as action_amount_gbp
    from rpt_aml.risk_sar_value_rate_kri_aggregation
    where risk_sar_value_rate_kri_aggregation.action_completed_at_timestamp
            >= '2025-01-01'
        and risk_sar_value_rate_kri_aggregation.action_completed_at_timestamp
            < '2026-05-03'
        and risk_sar_value_rate_kri_aggregation.included_in_90d_sar_vol_kri = true
        and risk_sar_value_rate_kri_aggregation.subject_alert_type_enhanced
            is not null
    group by risk_sar_value_rate_kri_aggregation.money_movement_id
),
proposed_actions as (
    select
        sar_action_fact.money_movement_id,
        sar_action_fact.action_amount_gbp
    from sandbox_db.limited_sandbox_fincrime_analytics.sar_action_fact
        as sar_action_fact
    where sar_action_fact.action_completed_at_timestamp >= '2025-01-01'
        and sar_action_fact.action_completed_at_timestamp < '2026-05-03'
),
comparison as (
    select
        coalesce(
            current_actions.money_movement_id,
            proposed_actions.money_movement_id
        ) as money_movement_id,
        current_actions.action_amount_gbp as current_value_gbp,
        proposed_actions.action_amount_gbp as proposed_value_gbp,
        case
            when current_actions.money_movement_id is not null
                and proposed_actions.money_movement_id is not null then 'BOTH'
            when current_actions.money_movement_id is not null then 'CURRENT_ONLY'
            else 'PROPOSED_ONLY'
        end as comparison_bucket
    from current_actions
    full outer join proposed_actions
        on proposed_actions.money_movement_id = current_actions.money_movement_id
),
by_bucket as (
    select
        comparison.comparison_bucket,
        count(*) as money_movement_count,
        round(sum(coalesce(comparison.current_value_gbp, 0)), 2)
            as current_value_gbp,
        round(sum(coalesce(comparison.proposed_value_gbp, 0)), 2)
            as proposed_value_gbp
    from comparison
    group by comparison.comparison_bucket
),
totals as (
    select
        'TOTAL' as comparison_bucket,
        count(*) as money_movement_count,
        round(sum(coalesce(comparison.current_value_gbp, 0)), 2)
            as current_value_gbp,
        round(sum(coalesce(comparison.proposed_value_gbp, 0)), 2)
            as proposed_value_gbp
    from comparison
),
final as (
    select * from by_bucket
    union all
    select * from totals
)
select
    final.*,
    final.proposed_value_gbp - final.current_value_gbp as value_change_gbp,
    round(
        100 * div0(
            final.proposed_value_gbp - final.current_value_gbp,
            final.current_value_gbp
        ),
        4
    ) as value_change_pct
from final
order by final.comparison_bucket
;
