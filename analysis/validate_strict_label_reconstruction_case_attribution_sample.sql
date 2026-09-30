-- Aggregate-only validation for the strict reconstruction sample.

with base as (
    select *
    from sandbox_db.limited_sandbox_fincrime_analytics.sar_label_reconstruction_case_attribution_sample
),

totals as (
    select
        count(*) as row_count,
        count(distinct base.label_lifecycle_key) as lifecycle_count
    from base
),

reconstruction_status as (
    select
        'RECONSTRUCTION_STATUS' as category,
        base.reconstruction_status as status,
        count(*) as row_count,
        count(distinct base.label_lifecycle_key) as lifecycle_count
    from base
    group by base.reconstruction_status
),

case_attribution_status as (
    select
        'CASE_ATTRIBUTION_STATUS' as category,
        base.case_attribution_status as status,
        count(*) as row_count,
        count(distinct base.label_lifecycle_key) as lifecycle_count
    from base
    group by base.case_attribution_status
),

duplicate_interval_keys as (
    select
        base.label_value_interval_key,
        count(*) as duplicate_row_count
    from base
    where base.label_value_interval_key is not null
    group by base.label_value_interval_key
    having count(*) > 1
),

multiple_active_intervals as (
    select
        base.label_lifecycle_key,
        count_if(base.is_currently_active) as active_row_count
    from base
    group by base.label_lifecycle_key
    having count_if(base.is_currently_active) > 1
),

quality_checks as (
    select
        'QUALITY_CHECK' as category,
        'TOTAL' as status,
        totals.row_count,
        totals.lifecycle_count
    from totals

    union all

    select
        'QUALITY_CHECK',
        'DUPLICATE_NON_NULL_INTERVAL_KEYS',
        coalesce(sum(duplicate_interval_keys.duplicate_row_count), 0),
        count(*)
    from duplicate_interval_keys

    union all

    select
        'QUALITY_CHECK',
        'LIFECYCLES_WITH_MULTIPLE_ACTIVE_INTERVALS',
        coalesce(sum(multiple_active_intervals.active_row_count), 0),
        count(*)
    from multiple_active_intervals

    union all

    select
        'QUALITY_CHECK',
        'ROWS_WITH_LABEL_ID',
        count_if(base.label_id is not null),
        count(distinct iff(
            base.label_id is not null,
            base.label_lifecycle_key,
            null
        ))
    from base

    union all

    select
        'QUALITY_CHECK',
        'ROWS_WITH_CANDIDATE_ORIGIN_CASE',
        count_if(base.candidate_origin_case_id is not null),
        count(distinct iff(
            base.candidate_origin_case_id is not null,
            base.label_lifecycle_key,
            null
        ))
    from base
),

combined as (
    select * from reconstruction_status
    union all
    select * from case_attribution_status
    union all
    select * from quality_checks
),

final as (
    select
        combined.category,
        combined.status,
        combined.row_count,
        combined.lifecycle_count,
        round(
            100 * combined.lifecycle_count
                / nullif(totals.lifecycle_count, 0),
            2
        ) as pct_of_lifecycles
    from combined
    cross join totals
)

select *
from final
order by final.category, final.lifecycle_count desc
;
