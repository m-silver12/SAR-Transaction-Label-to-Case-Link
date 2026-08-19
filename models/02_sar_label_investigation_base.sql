-- Grain: one row per label interval + money movement + investigation case.

create or replace table
    sandbox_db.limited_sandbox_fincrime_analytics.sar_label_investigation_base as
with label_intervals as (
    select *
    from sandbox_db.limited_sandbox_fincrime_analytics.sar_label_intervals
    where coalesce(typology_group_raw, '') != 'FRAUD'
),
transfer_label_actions as (
    select distinct
        label_intervals.*,
        'TRANSFER_REQUEST_ID_TO_REPORT_ACTION_STEP' as bridge_path,
        report_action_step.action_id::string as money_movement_id
    from label_intervals
    inner join rpt_analytics_experience.report_action_step
        on report_action_step.request_id
            = try_to_number(label_intervals.entity_id)
    where label_intervals.entity_type = 'TRANSFER'
        and try_to_number(label_intervals.entity_id) is not null
        and report_action_step.action_id is not null
),
card_label_actions as (
    select distinct
        label_intervals.*,
        'CARD_PLASTIC_TRANSACTION_ID_TO_REPORT_ACTION_STEP' as bridge_path,
        report_action_step.action_id::string as money_movement_id
    from label_intervals
    inner join rpt_analytics_experience.report_action_step
        on report_action_step.plastic_transaction_id
            = try_to_number(label_intervals.entity_id)
    where label_intervals.entity_type = 'CARD_TRANSACTION'
        and try_to_number(label_intervals.entity_id) is not null
        and report_action_step.action_id is not null
        and report_action_step.balance_step_type in ('WITHDRAWAL', 'DEPOSIT')
        and report_action_step.not_duplicate = 1
),
direct_debit_label_actions as (
    select distinct
        label_intervals.*,
        'DIRECT_DEBIT_TO_BALANCE_TRANSACTION_TO_REPORT_ACTION_STEP'
            as bridge_path,
        report_action_step.action_id::string as money_movement_id
    from label_intervals
    inner join borderless_dd.transaction as direct_debit_transaction
        on direct_debit_transaction.id::string
            = label_intervals.entity_id::string
    inner join rpt_analytics_experience.report_action_step
        on report_action_step.balance_transaction_id
            = direct_debit_transaction.balance_transaction_id
    where label_intervals.entity_type = 'DIRECT_DEBIT_TRANSACTION'
        and report_action_step.action_id is not null
        and report_action_step.balance_step_type = 'WITHDRAWAL'
        and report_action_step.not_duplicate = 1
),
label_actions as (
    select * from transfer_label_actions
    union all
    select * from card_label_actions
    union all
    select * from direct_debit_label_actions
),
money_movements as (
    select
        money_movement_core.money_movement_id::string as money_movement_id,
        money_movement_core.profile_id as transaction_profile_id,
        money_movement_core.action_completed_at_timestamp,
        money_movement_core.action_amount_gbp,
        money_movement_core.product_type,
        money_movement_core.action_type,
        money_movement_core.source_currency,
        money_movement_core.target_currency
    from rpt_core_analytics.money_movement_core
    where money_movement_core.money_movement_id is not null
        and money_movement_core.is_duplicate_money_movement = false
        and money_movement_core.is_successful_money_movement = true
        and money_movement_core.aggregation_type in ('same_ccy', 'cross_ccy')
),
labelled_money_movements as (
    select distinct
        label_actions.*,
        money_movements.transaction_profile_id,
        money_movements.action_completed_at_timestamp,
        money_movements.action_amount_gbp,
        money_movements.product_type,
        money_movements.action_type,
        money_movements.source_currency,
        money_movements.target_currency,
        datediff(
            day,
            money_movements.action_completed_at_timestamp,
            label_actions.label_created_at
        ) as action_to_label_days,
        datediff(
            day,
            money_movements.action_completed_at_timestamp,
            label_actions.label_created_at
        ) <= 90 as included_in_90d_sar_value
    from label_actions
    inner join money_movements
        on money_movements.money_movement_id
            = label_actions.money_movement_id
),
cases as (
    select
        risk_aml_subjects.profile_id,
        risk_aml_subjects.case_id_inv,
        risk_aml_subjects.case_id_reporting,
        risk_aml_subjects.is_externally_reported,
        risk_aml_subjects.subject_alert_type_enhanced,
        risk_aml_subjects.subject_alert_type_grouped,
        risk_aml_subjects.is_primary_alerted_profile,
        risk_aml_subjects.investigation_case_creation_date,
        risk_aml_subjects.reporting_case_resolution_date,
        risk_aml_subjects.external_report_date,
        coalesce(
            risk_inv_case_base.case_resolution_timestamp,
            risk_aml_subjects.reporting_case_resolution_date::timestamp_ntz
        ) as case_link_timestamp
    from rpt_aml.risk_aml_subjects
    left join rpt_aml.risk_inv_case_base
        on risk_inv_case_base.case_id_inv = risk_aml_subjects.case_id_inv
    where risk_aml_subjects.case_id_inv is not null
    qualify row_number() over (
        partition by
            risk_aml_subjects.profile_id,
            risk_aml_subjects.case_id_inv
        order by
            risk_aml_subjects.is_primary_alerted_profile desc nulls last,
            risk_aml_subjects.subject_alert_type_enhanced nulls last,
            risk_aml_subjects.investigation_case_creation_date nulls last
    ) = 1
),
final as (
    select
        labelled_money_movements.*,
        cases.case_id_inv,
        cases.case_id_reporting,
        cases.is_externally_reported,
        cases.subject_alert_type_enhanced,
        cases.subject_alert_type_grouped,
        cases.is_primary_alerted_profile,
        cases.investigation_case_creation_date,
        cases.reporting_case_resolution_date,
        cases.external_report_date,
        cases.case_link_timestamp,
        dense_rank() over (
            partition by labelled_money_movements.label_uid
            order by cases.case_link_timestamp, cases.case_id_inv
        ) as investigation_case_link_rank
    from labelled_money_movements
    inner join cases
        on cases.profile_id
            = labelled_money_movements.transaction_profile_id
        and cases.case_link_timestamp
            >= labelled_money_movements.label_value_active_from
        and cases.case_link_timestamp
            < labelled_money_movements.label_value_active_to
)
select
    final.*,
    final.investigation_case_link_rank = 1
        as is_first_investigation_case_linked_to_label_id
from final
;
