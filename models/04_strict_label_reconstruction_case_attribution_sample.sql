-- This is an evidence model, not the deduplicated SAR-value numerator.
-- FINCRIME_LABEL.LABEL_CHANGE_LOG.ID is an event ID, not the immutable label ID.
--
-- Output grain:
--   one row per reconstructed label-value interval, plus one unresolved row
--   for every entity scope whose history cannot be safely reconstructed.
--   Case associations from AML_RISK.FINCRIME_LABEL are aggregated back to the
--   lifecycle so that one label linked to several cases does not fan out rows.
--
-- Left-censored history:
--   if the first event is UPDATE and the remaining sequence is unambiguous,
--   that UPDATE timestamp is retained as the observed start of the new value.
--   It is not presented as the original label-creation timestamp. DELETE-first
--   histories keep a null start because no defensible start date is available.
--
-- Validation scope:
--   transaction-label scopes observed during September 2026, sampled
--   deterministically to 1/64 using the natural transaction-label scope key.
--   After selecting those scopes, the model reads all available events for each
--   selected scope so their reconstructed intervals are not truncated to the
--   September observation window.
--
create or replace table
    sandbox_db.limited_sandbox_fincrime_analytics.sar_label_reconstruction_case_attribution_sample
as
with validation_scopes as (
    select distinct
        label_change_log.owner_entity_id,
        label_change_log.owner_entity_type,
        label_change_log.entity_id,
        label_change_log.entity_type,
        label_change_log.team
    from analytics_db.fincrime_label.label_change_log
    where label_change_log.team = 'AML'
        and label_change_log.owner_entity_type = 'PROFILE'
        and label_change_log.entity_type in (
            'TRANSFER',
            'CARD_TRANSACTION',
            'DIRECT_DEBIT_TRANSACTION'
        )
        and label_change_log.created_at >= '2026-09-01'
        and label_change_log.created_at < '2026-10-01'
        and bitand(
            hash(
                label_change_log.owner_entity_id,
                label_change_log.owner_entity_type,
                label_change_log.entity_id,
                label_change_log.entity_type,
                label_change_log.team
            ),
            63
        ) = 0
),

label_events_source as (
    select
        label_change_log.id as label_change_log_id,
        label_change_log.owner_entity_id,
        label_change_log.owner_entity_type,
        label_change_log.entity_id,
        label_change_log.entity_type,
        label_change_log.team,
        label_change_log.label,
        label_change_log.event_type,
        label_change_log.actor,
        label_change_log.actor_type,
        label_change_log.created_at as event_at,
        label_change_log._sdc_batched_at
    from analytics_db.fincrime_label.label_change_log
    inner join validation_scopes
        on validation_scopes.owner_entity_id
            = label_change_log.owner_entity_id
        and validation_scopes.owner_entity_type
            = label_change_log.owner_entity_type
        and validation_scopes.entity_id = label_change_log.entity_id
        and validation_scopes.entity_type = label_change_log.entity_type
        and validation_scopes.team = label_change_log.team
    where label_change_log.team = 'AML'
        and label_change_log.owner_entity_type = 'PROFILE'
        and label_change_log.entity_type in (
            'TRANSFER',
            'CARD_TRANSACTION',
            'DIRECT_DEBIT_TRANSACTION'
        )
),

ordered_events as (
    select
        label_events_source.*,
        case
            when label_events_source.event_type = 'INSERT' then 1
            when label_events_source.event_type = 'DELETE' then -1
            else 0
        end as active_label_delta,
        lag(label_events_source.label) over (
            partition by
                label_events_source.owner_entity_id,
                label_events_source.owner_entity_type,
                label_events_source.entity_id,
                label_events_source.entity_type,
                label_events_source.team
            order by
                label_events_source.event_at,
                label_events_source.label_change_log_id
        ) as previous_event_label,
        row_number() over (
            partition by
                label_events_source.owner_entity_id,
                label_events_source.owner_entity_type,
                label_events_source.entity_id,
                label_events_source.entity_type,
                label_events_source.team
            order by
                label_events_source.event_at,
                label_events_source.label_change_log_id
        ) as event_sequence,
        sum(
            case
                when label_events_source.event_type = 'INSERT' then 1
                when label_events_source.event_type = 'DELETE' then -1
                else 0
            end
        ) over (
            partition by
                label_events_source.owner_entity_id,
                label_events_source.owner_entity_type,
                label_events_source.entity_id,
                label_events_source.entity_type,
                label_events_source.team
            order by
                label_events_source.event_at,
                label_events_source.label_change_log_id
            rows between unbounded preceding and current row
        ) as active_label_count_after_event
    from label_events_source
),

scope_diagnostics as (
    select
        ordered_events.owner_entity_id,
        ordered_events.owner_entity_type,
        ordered_events.entity_id,
        ordered_events.entity_type,
        ordered_events.team,
        min(
            ordered_events.active_label_count_after_event
                - ordered_events.active_label_delta
        ) as min_active_label_count_before_event,
        max(ordered_events.active_label_count_after_event)
            as max_active_label_count_after_event,
        count_if(ordered_events.event_type = 'INSERT') as insert_event_count,
        count_if(ordered_events.event_type = 'DELETE') as delete_event_count,
        count_if(ordered_events.event_type = 'UPDATE') as update_event_count,
        count_if(ordered_events.event_at is null)
            as null_event_timestamp_count,
        count_if(
            ordered_events.event_type = 'UPDATE'
            and ordered_events.active_label_count_after_event != 1
        ) as invalid_update_context_count,
        min_by(ordered_events.event_type, ordered_events.event_sequence)
            as first_event_type,
        max(ordered_events.active_label_count_after_event)
            - min(ordered_events.active_label_count_after_event)
            as active_count_range
    from ordered_events
    group by
        ordered_events.owner_entity_id,
        ordered_events.owner_entity_type,
        ordered_events.entity_id,
        ordered_events.entity_type,
        ordered_events.team
),

classified_scopes as (
    select
        scope_diagnostics.*,
        case
            when scope_diagnostics.null_event_timestamp_count > 0
                or scope_diagnostics.first_event_type != 'INSERT'
                or scope_diagnostics.min_active_label_count_before_event < 0
                then 'INCOMPLETE_HISTORY'
            when scope_diagnostics.max_active_label_count_after_event > 1
                and scope_diagnostics.update_event_count > 0
                then 'AMBIGUOUS_PARALLEL_UPDATE'
            when scope_diagnostics.invalid_update_context_count > 0
                then 'INCOMPLETE_HISTORY'
            when scope_diagnostics.max_active_label_count_after_event > 1
                then 'EXACT_PARALLEL_NO_UPDATE'
            else 'EXACT_SINGLE_ACTIVE_LABEL'
        end as reconstruction_status
    from scope_diagnostics
),

events_with_status as (
    select
        ordered_events.*,
        classified_scopes.first_event_type,
        classified_scopes.insert_event_count,
        classified_scopes.null_event_timestamp_count,
        classified_scopes.reconstruction_status
    from ordered_events
    inner join classified_scopes
        on classified_scopes.owner_entity_id = ordered_events.owner_entity_id
        and classified_scopes.owner_entity_type
            = ordered_events.owner_entity_type
        and classified_scopes.entity_id = ordered_events.entity_id
        and classified_scopes.entity_type = ordered_events.entity_type
        and classified_scopes.team = ordered_events.team
),

single_label_events as (
    select
        events_with_status.*,
        sum(iff(events_with_status.event_type = 'INSERT', 1, 0)) over (
            partition by
                events_with_status.owner_entity_id,
                events_with_status.owner_entity_type,
                events_with_status.entity_id,
                events_with_status.entity_type,
                events_with_status.team
            order by
                events_with_status.event_at,
                events_with_status.label_change_log_id
            rows between unbounded preceding and current row
        ) as lifecycle_sequence
    from events_with_status
    where events_with_status.reconstruction_status
        = 'EXACT_SINGLE_ACTIVE_LABEL'
),

meaningful_single_label_events as (
    select
        single_label_events.*
    from single_label_events
    where single_label_events.event_type in ('INSERT', 'DELETE')
        or (
            single_label_events.event_type = 'UPDATE'
            and coalesce(single_label_events.label, '__NULL__')
                != coalesce(single_label_events.previous_event_label, '__NULL__')
        )
),

single_label_intervals as (
    select
        meaningful_single_label_events.owner_entity_id,
        meaningful_single_label_events.owner_entity_type,
        meaningful_single_label_events.entity_id,
        meaningful_single_label_events.entity_type,
        meaningful_single_label_events.team,
        meaningful_single_label_events.lifecycle_sequence,
        meaningful_single_label_events.label,
        meaningful_single_label_events.actor as interval_started_by,
        meaningful_single_label_events.actor_type as interval_start_actor_type,
        meaningful_single_label_events.event_type as interval_start_event_type,
        meaningful_single_label_events.label_change_log_id
            as interval_start_event_id,
        meaningful_single_label_events.event_at as label_value_active_from,
        coalesce(
            lead(meaningful_single_label_events.event_at) over (
                partition by
                    meaningful_single_label_events.owner_entity_id,
                    meaningful_single_label_events.owner_entity_type,
                    meaningful_single_label_events.entity_id,
                    meaningful_single_label_events.entity_type,
                    meaningful_single_label_events.team,
                    meaningful_single_label_events.lifecycle_sequence
                order by
                    meaningful_single_label_events.event_at,
                    meaningful_single_label_events.label_change_log_id
            ),
            to_timestamp_ntz('9999-01-01')
        ) as label_value_active_to,
        meaningful_single_label_events.reconstruction_status
    from meaningful_single_label_events
    qualify meaningful_single_label_events.event_type in ('INSERT', 'UPDATE')
),

left_censored_events as (
    select
        events_with_status.*,
        count_if(events_with_status.event_type = 'DELETE') over (
            partition by
                events_with_status.owner_entity_id,
                events_with_status.owner_entity_type,
                events_with_status.entity_id,
                events_with_status.entity_type,
                events_with_status.team
            order by
                events_with_status.event_at,
                events_with_status.label_change_log_id
            rows between unbounded preceding and 1 preceding
        ) as prior_delete_count
    from events_with_status
    where events_with_status.reconstruction_status = 'INCOMPLETE_HISTORY'
        and events_with_status.first_event_type = 'UPDATE'
        and events_with_status.insert_event_count = 0
        and events_with_status.null_event_timestamp_count = 0
),

meaningful_left_censored_events as (
    select
        left_censored_events.*
    from left_censored_events
    where coalesce(left_censored_events.prior_delete_count, 0) = 0
        and (
            left_censored_events.event_type = 'DELETE'
            or (
                left_censored_events.event_type = 'UPDATE'
                and (
                    left_censored_events.event_sequence = 1
                    or coalesce(left_censored_events.label, '__NULL__')
                        != coalesce(
                            left_censored_events.previous_event_label,
                            '__NULL__'
                        )
                )
            )
        )
),

left_censored_update_intervals as (
    select
        meaningful_left_censored_events.owner_entity_id,
        meaningful_left_censored_events.owner_entity_type,
        meaningful_left_censored_events.entity_id,
        meaningful_left_censored_events.entity_type,
        meaningful_left_censored_events.team,
        0 as lifecycle_sequence,
        meaningful_left_censored_events.label,
        meaningful_left_censored_events.actor as interval_started_by,
        meaningful_left_censored_events.actor_type
            as interval_start_actor_type,
        meaningful_left_censored_events.event_type
            as interval_start_event_type,
        meaningful_left_censored_events.label_change_log_id
            as interval_start_event_id,
        meaningful_left_censored_events.event_at as label_value_active_from,
        coalesce(
            lead(meaningful_left_censored_events.event_at) over (
                partition by
                    meaningful_left_censored_events.owner_entity_id,
                    meaningful_left_censored_events.owner_entity_type,
                    meaningful_left_censored_events.entity_id,
                    meaningful_left_censored_events.entity_type,
                    meaningful_left_censored_events.team
                order by
                    meaningful_left_censored_events.event_at,
                    meaningful_left_censored_events.label_change_log_id
            ),
            to_timestamp_ntz('9999-01-01')
        ) as label_value_active_to,
        'LEFT_CENSORED_UPDATE_START' as reconstruction_status
    from meaningful_left_censored_events
    qualify meaningful_left_censored_events.event_type = 'UPDATE'
),

parallel_label_start_events as (
    select
        events_with_status.*,
        row_number() over (
            partition by
                events_with_status.owner_entity_id,
                events_with_status.owner_entity_type,
                events_with_status.entity_id,
                events_with_status.entity_type,
                events_with_status.team,
                events_with_status.label
            order by
                events_with_status.event_at,
                events_with_status.label_change_log_id
        ) as label_occurrence,
        row_number() over (
            partition by
                events_with_status.owner_entity_id,
                events_with_status.owner_entity_type,
                events_with_status.entity_id,
                events_with_status.entity_type,
                events_with_status.team
            order by
                events_with_status.event_at,
                events_with_status.label_change_log_id
        ) as scope_lifecycle_sequence
    from events_with_status
    where events_with_status.reconstruction_status
        = 'EXACT_PARALLEL_NO_UPDATE'
        and events_with_status.event_type = 'INSERT'
),

parallel_label_end_events as (
    select
        events_with_status.*,
        row_number() over (
            partition by
                events_with_status.owner_entity_id,
                events_with_status.owner_entity_type,
                events_with_status.entity_id,
                events_with_status.entity_type,
                events_with_status.team,
                events_with_status.label
            order by
                events_with_status.event_at,
                events_with_status.label_change_log_id
        ) as label_occurrence
    from events_with_status
    where events_with_status.reconstruction_status
        = 'EXACT_PARALLEL_NO_UPDATE'
        and events_with_status.event_type = 'DELETE'
),

parallel_label_intervals as (
    select
        parallel_label_start_events.owner_entity_id,
        parallel_label_start_events.owner_entity_type,
        parallel_label_start_events.entity_id,
        parallel_label_start_events.entity_type,
        parallel_label_start_events.team,
        parallel_label_start_events.scope_lifecycle_sequence
            as lifecycle_sequence,
        parallel_label_start_events.label,
        parallel_label_start_events.actor as interval_started_by,
        parallel_label_start_events.actor_type as interval_start_actor_type,
        parallel_label_start_events.event_type as interval_start_event_type,
        parallel_label_start_events.label_change_log_id
            as interval_start_event_id,
        parallel_label_start_events.event_at as label_value_active_from,
        coalesce(
            parallel_label_end_events.event_at,
            to_timestamp_ntz('9999-01-01')
        ) as label_value_active_to,
        parallel_label_start_events.reconstruction_status
    from parallel_label_start_events
    left join parallel_label_end_events
        on parallel_label_end_events.owner_entity_id
            = parallel_label_start_events.owner_entity_id
        and parallel_label_end_events.owner_entity_type
            = parallel_label_start_events.owner_entity_type
        and parallel_label_end_events.entity_id
            = parallel_label_start_events.entity_id
        and parallel_label_end_events.entity_type
            = parallel_label_start_events.entity_type
        and parallel_label_end_events.team = parallel_label_start_events.team
        and parallel_label_end_events.label = parallel_label_start_events.label
        and parallel_label_end_events.label_occurrence
            = parallel_label_start_events.label_occurrence
),

reconstructed_intervals as (
    select * from single_label_intervals
    union all
    select * from parallel_label_intervals
    union all
    select * from left_censored_update_intervals
),

intervals_with_keys as (
    select
        md5(concat_ws(
            '|',
            reconstructed_intervals.owner_entity_id,
            reconstructed_intervals.owner_entity_type,
            reconstructed_intervals.entity_id,
            reconstructed_intervals.entity_type,
            reconstructed_intervals.team,
            reconstructed_intervals.lifecycle_sequence::string
        )) as label_lifecycle_key,
        md5(concat_ws(
            '|',
            reconstructed_intervals.owner_entity_id,
            reconstructed_intervals.owner_entity_type,
            reconstructed_intervals.entity_id,
            reconstructed_intervals.entity_type,
            reconstructed_intervals.team,
            reconstructed_intervals.interval_start_event_id::string
        )) as label_value_interval_key,
        reconstructed_intervals.*
    from reconstructed_intervals
),

current_labels as (
    select
        fincrime_labels.id as label_id,
        fincrime_labels.owner_entity_id,
        fincrime_labels.owner_entity_type,
        fincrime_labels.entity_id,
        fincrime_labels.entity_type,
        fincrime_labels.team,
        fincrime_labels.label,
        fincrime_labels.created_at as current_label_created_at,
        fincrime_labels.updated_at as current_label_updated_at
    from analytics_db.fincrime_label.fincrime_labels
    where fincrime_labels.team = 'AML'
        and fincrime_labels._sdc_deleted_at is null
),

current_lifecycle_labels as (
    select distinct
        intervals_with_keys.label_lifecycle_key,
        current_labels.label_id,
        current_labels.label as current_label_value
    from intervals_with_keys
    inner join current_labels
        on current_labels.owner_entity_id = intervals_with_keys.owner_entity_id
        and current_labels.owner_entity_type
            = intervals_with_keys.owner_entity_type
        and current_labels.entity_id = intervals_with_keys.entity_id
        and current_labels.entity_type = intervals_with_keys.entity_type
        and current_labels.team = intervals_with_keys.team
        and current_labels.label = intervals_with_keys.label
        and intervals_with_keys.label_value_active_to
            = to_timestamp_ntz('9999-01-01')
),

resolved_intervals as (
    select
        intervals_with_keys.label_lifecycle_key,
        intervals_with_keys.label_value_interval_key,
        current_lifecycle_labels.label_id,
        intervals_with_keys.owner_entity_id,
        intervals_with_keys.owner_entity_type,
        intervals_with_keys.entity_id,
        intervals_with_keys.entity_type,
        intervals_with_keys.team,
        intervals_with_keys.label,
        intervals_with_keys.interval_started_by,
        intervals_with_keys.interval_start_actor_type,
        intervals_with_keys.interval_start_event_type,
        intervals_with_keys.interval_start_event_id,
        intervals_with_keys.label_value_active_from,
        intervals_with_keys.label_value_active_to,
        intervals_with_keys.label_value_active_to
            = to_timestamp_ntz('9999-01-01')
            and current_lifecycle_labels.label_id is not null
            as is_currently_active,
        intervals_with_keys.reconstruction_status
    from intervals_with_keys
    left join current_lifecycle_labels
        on current_lifecycle_labels.label_lifecycle_key
            = intervals_with_keys.label_lifecycle_key
),

label_lifecycles as (
    select
        resolved_intervals.label_lifecycle_key,
        resolved_intervals.label_id,
        min(resolved_intervals.label_value_active_from)
            as label_lifecycle_created_at,
        min_by(
            resolved_intervals.interval_start_event_type,
            resolved_intervals.label_value_active_from
        ) as label_lifecycle_start_event_type
    from resolved_intervals
    group by
        resolved_intervals.label_lifecycle_key,
        resolved_intervals.label_id
),

label_case_bridge_source as (
    select
        fincrime_label.id as label_case_bridge_id,
        fincrime_label.label_id,
        fincrime_label.dd_case_id,
        fincrime_label.created_at as case_bridge_created_at,
        fincrime_label._sdc_extracted_at
    from analytics_db.aml_risk.fincrime_label
    where fincrime_label._sdc_deleted_at is null
),

label_case_candidates as (
    select
        label_lifecycles.label_lifecycle_key,
        label_lifecycles.label_id,
        label_lifecycles.label_lifecycle_created_at,
        label_lifecycles.label_lifecycle_start_event_type,
        label_case_bridge_source.label_case_bridge_id,
        label_case_bridge_source.dd_case_id,
        label_case_bridge_source.case_bridge_created_at,
        row_number() over (
            partition by label_lifecycles.label_lifecycle_key
            order by
                label_case_bridge_source.case_bridge_created_at,
                label_case_bridge_source._sdc_extracted_at,
                label_case_bridge_source.label_case_bridge_id
        ) as retained_case_association_rank
    from label_lifecycles
    inner join label_case_bridge_source
        on label_case_bridge_source.label_id = label_lifecycles.label_id
),

label_case_summary as (
    select
        label_case_candidates.label_lifecycle_key,
        count(distinct label_case_candidates.dd_case_id)
            as retained_case_association_count,
        array_agg(distinct label_case_candidates.dd_case_id)
            within group (order by label_case_candidates.dd_case_id)
            as retained_case_ids,
        min(iff(
            label_case_candidates.retained_case_association_rank = 1,
            label_case_candidates.dd_case_id,
            null
        )) as earliest_retained_case_association_id,
        min(iff(
            label_case_candidates.retained_case_association_rank = 1,
            label_case_candidates.case_bridge_created_at,
            null
        )) as earliest_retained_case_bridge_date,
        count(distinct iff(
            label_case_candidates.label_lifecycle_start_event_type = 'INSERT'
                and
            label_case_candidates.case_bridge_created_at::date
                = label_case_candidates.label_lifecycle_created_at::date,
            label_case_candidates.dd_case_id,
            null
        )) as same_day_case_count,
        iff(
            count(distinct iff(
                label_case_candidates.label_lifecycle_start_event_type = 'INSERT'
                    and
                label_case_candidates.case_bridge_created_at::date
                    = label_case_candidates.label_lifecycle_created_at::date,
                label_case_candidates.dd_case_id,
                null
            )) = 1,
            min(iff(
                label_case_candidates.label_lifecycle_start_event_type = 'INSERT'
                    and
                label_case_candidates.case_bridge_created_at::date
                    = label_case_candidates.label_lifecycle_created_at::date,
                label_case_candidates.dd_case_id,
                null
            )),
            null
        ) as candidate_origin_case_id
    from label_case_candidates
    group by label_case_candidates.label_lifecycle_key
),

resolved_intervals_with_cases as (
    select
        resolved_intervals.*,
        label_case_summary.retained_case_association_count,
        label_case_summary.retained_case_ids,
        label_case_summary.earliest_retained_case_association_id,
        label_case_summary.earliest_retained_case_bridge_date,
        label_case_summary.same_day_case_count,
        label_case_summary.candidate_origin_case_id,
        case
            when resolved_intervals.label_id is null then 'NO_LABEL_ID'
            when label_lifecycles.label_lifecycle_start_event_type != 'INSERT'
                then 'ORIGIN_EVENT_NOT_OBSERVED'
            when label_case_summary.label_lifecycle_key is null
                then 'NO_RETAINED_CASE_ASSOCIATION'
            when label_case_summary.same_day_case_count = 1
                then 'UNIQUE_SAME_DAY_CANDIDATE_ORIGIN'
            when label_case_summary.same_day_case_count > 1
                then 'MULTIPLE_SAME_DAY_CASES'
            else 'LATER_CASE_ASSOCIATION_ONLY'
        end as case_attribution_status
    from resolved_intervals
    left join label_case_summary
        on label_case_summary.label_lifecycle_key
            = resolved_intervals.label_lifecycle_key
    left join label_lifecycles
        on label_lifecycles.label_lifecycle_key
            = resolved_intervals.label_lifecycle_key
),

unresolved_scopes as (
    select
        md5(concat_ws(
            '|',
            classified_scopes.owner_entity_id,
            classified_scopes.owner_entity_type,
            classified_scopes.entity_id,
            classified_scopes.entity_type,
            classified_scopes.team,
            'UNRESOLVED'
        )) as label_lifecycle_key,
        null::varchar as label_value_interval_key,
        null::number as label_id,
        classified_scopes.owner_entity_id,
        classified_scopes.owner_entity_type,
        classified_scopes.entity_id,
        classified_scopes.entity_type,
        classified_scopes.team,
        null::varchar as label,
        null::varchar as interval_started_by,
        null::varchar as interval_start_actor_type,
        null::varchar as interval_start_event_type,
        null::number as interval_start_event_id,
        null::timestamp_ntz as label_value_active_from,
        null::timestamp_ntz as label_value_active_to,
        false as is_currently_active,
        classified_scopes.reconstruction_status,
        null::number as retained_case_association_count,
        null::array as retained_case_ids,
        null::number as earliest_retained_case_association_id,
        null::timestamp_ntz as earliest_retained_case_bridge_date,
        null::number as same_day_case_count,
        null::number as candidate_origin_case_id,
        'LABEL_HISTORY_UNRESOLVED' as case_attribution_status
    from classified_scopes
    where classified_scopes.reconstruction_status in (
        'INCOMPLETE_HISTORY',
        'AMBIGUOUS_PARALLEL_UPDATE'
    )
        and not (
            classified_scopes.reconstruction_status = 'INCOMPLETE_HISTORY'
            and classified_scopes.first_event_type = 'UPDATE'
            and classified_scopes.insert_event_count = 0
            and classified_scopes.null_event_timestamp_count = 0
        )
),

final as (
    select * from resolved_intervals_with_cases
    union all
    select * from unresolved_scopes
)

select *
from final
;
