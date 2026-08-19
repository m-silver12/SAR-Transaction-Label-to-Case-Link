-- Grain: one row per period in which a transaction-label value was active.

create or replace table
    sandbox_db.limited_sandbox_fincrime_analytics.sar_label_intervals as
with label_events as (
    select
        label_change_log.id as label_change_log_id,
        label_change_log.team,
        label_change_log.actor,
        label_change_log.actor_type,
        label_change_log.label,
        label_change_log.entity_id,
        label_change_log.entity_type,
        label_change_log.owner_entity_id,
        label_change_log.owner_entity_type,
        label_change_log.event_type,
        label_change_log.created_at
    from fincrime_label.label_change_log
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
        label_events.*,
        lag(label_events.label) over (
            partition by
                label_events.owner_entity_id,
                label_events.owner_entity_type,
                label_events.entity_id,
                label_events.entity_type,
                label_events.team
            order by label_events.created_at, label_events.label_change_log_id
        ) as previous_label,
        sum(iff(label_events.event_type = 'INSERT', 1, 0)) over (
            partition by
                label_events.owner_entity_id,
                label_events.owner_entity_type,
                label_events.entity_id,
                label_events.entity_type,
                label_events.team
            order by label_events.created_at, label_events.label_change_log_id
            rows between unbounded preceding and current row
        ) as lifecycle_sequence
    from label_events
),
events_with_lifecycle as (
    select
        ordered_events.*,
        coalesce(
            min(iff(
                ordered_events.event_type = 'INSERT',
                ordered_events.created_at,
                null
            )) over (
                partition by
                    ordered_events.owner_entity_id,
                    ordered_events.owner_entity_type,
                    ordered_events.entity_id,
                    ordered_events.entity_type,
                    ordered_events.team,
                    ordered_events.lifecycle_sequence
            ),
            min(ordered_events.created_at) over (
                partition by
                    ordered_events.owner_entity_id,
                    ordered_events.owner_entity_type,
                    ordered_events.entity_id,
                    ordered_events.entity_type,
                    ordered_events.team,
                    ordered_events.lifecycle_sequence
            )
        ) as label_lifecycle_created_at
    from ordered_events
),
start_events as (
    select
        events_with_lifecycle.*,
        row_number() over (
            partition by
                events_with_lifecycle.owner_entity_id,
                events_with_lifecycle.owner_entity_type,
                events_with_lifecycle.entity_id,
                events_with_lifecycle.entity_type,
                events_with_lifecycle.team,
                events_with_lifecycle.label
            order by
                events_with_lifecycle.created_at,
                events_with_lifecycle.label_change_log_id
        ) as start_sequence
    from events_with_lifecycle
    where events_with_lifecycle.event_type = 'INSERT'
        or (
            events_with_lifecycle.event_type = 'UPDATE'
            and coalesce(events_with_lifecycle.label, '__NULL__')
                != coalesce(events_with_lifecycle.previous_label, '__NULL__')
        )
),
end_events as (
    select
        events_with_lifecycle.*,
        iff(
            events_with_lifecycle.event_type = 'UPDATE',
            events_with_lifecycle.previous_label,
            events_with_lifecycle.label
        ) as ended_label,
        row_number() over (
            partition by
                events_with_lifecycle.owner_entity_id,
                events_with_lifecycle.owner_entity_type,
                events_with_lifecycle.entity_id,
                events_with_lifecycle.entity_type,
                events_with_lifecycle.team,
                iff(
                    events_with_lifecycle.event_type = 'UPDATE',
                    events_with_lifecycle.previous_label,
                    events_with_lifecycle.label
                )
            order by
                events_with_lifecycle.created_at,
                events_with_lifecycle.label_change_log_id
        ) as end_sequence
    from events_with_lifecycle
    where events_with_lifecycle.event_type = 'DELETE'
        or (
            events_with_lifecycle.event_type = 'UPDATE'
            and events_with_lifecycle.previous_label is not null
            and coalesce(events_with_lifecycle.label, '__NULL__')
                != coalesce(events_with_lifecycle.previous_label, '__NULL__')
        )
),
final as (
    select
        md5(concat_ws(
            '|',
            start_events.owner_entity_id,
            start_events.owner_entity_type,
            start_events.entity_id,
            start_events.entity_type,
            start_events.team,
            start_events.label,
            start_events.label_change_log_id::string
        )) as label_uid,
        start_events.owner_entity_id as label_owner_profile_id,
        start_events.entity_id,
        start_events.entity_type,
        start_events.team,
        start_events.label,
        split_part(start_events.label, '.', 1) as typology_group_raw,
        split_part(start_events.label, '.', 2) as typology,
        start_events.actor as label_value_started_by,
        end_events.actor as label_value_ended_by,
        start_events.label_lifecycle_created_at as label_created_at,
        start_events.created_at as label_value_active_from,
        coalesce(
            end_events.created_at,
            to_timestamp_ntz('9999-01-01')
        ) as label_value_active_to,
        start_events.event_type as label_start_event_type,
        end_events.event_type as label_end_event_type,
        start_events.label_change_log_id as label_start_event_id,
        end_events.label_change_log_id as label_end_event_id
    from start_events
    left join end_events
        on end_events.owner_entity_id = start_events.owner_entity_id
        and end_events.owner_entity_type = start_events.owner_entity_type
        and end_events.entity_id = start_events.entity_id
        and end_events.entity_type = start_events.entity_type
        and end_events.team = start_events.team
        and end_events.ended_label = start_events.label
        and end_events.end_sequence = start_events.start_sequence
)
select * from final
;
