{%- macro snowflake__hub(hashkey, business_keys, src_ldts, src_rsrc, source_models) -%}

{%- set end_of_all_times = datavault4dbt.end_of_all_times() -%}
{%- set timestamp_format = datavault4dbt.timestamp_format() -%}

{{ log('source_models'~source_models, false) }}

{%- set ns = namespace(last_cte= "", source_included_before = {}, has_rsrc_static_defined=true, source_models_rsrc_dict={}) -%}

{# Select the Business Key column from the first source model definition provided in the hub model and put them in an array. #}
{%- set business_keys = datavault4dbt.expand_column_list(columns=[business_keys]) -%}

{# If no specific bk_columns is defined for each source, we apply the values set in the business_keys variable. #}
{# If no specific hk_column is defined for each source, we apply the values set in the hashkey variable. #}
{# If no rsrc_static parameter is defined in ANY of the source models then the whole code block of record_source performance lookup is not executed  #}
{# For the use of record_source performance lookup it is required that every source model has the parameter rsrc_static defined and it cannot be an empty string #}
{%- if source_models is not mapping and not datavault4dbt.is_list(source_models) -%}
    {%- set source_models = {source_models: {}} -%}
{%- endif -%}

{%- set source_model_values = fromjson(datavault4dbt.source_model_processing(source_models=source_models, parameters={'hk_column':hashkey}, business_keys=business_keys)) -%}
{%- set source_models = source_model_values['source_model_list'] -%}
{%- set ns.has_rsrc_static_defined = source_model_values['has_rsrc_static_defined'] -%}
{%- set ns.source_models_rsrc_dict = source_model_values['source_models_rsrc_dict'] -%}
{{ log('source_models: '~source_models, true) }}

{%- set final_columns_to_select = [hashkey] + business_keys + [src_ldts] + [src_rsrc] -%}

{{ datavault4dbt.prepend_generated_by() }}

WITH

{% if is_incremental() -%}
{# Get all target hashkeys out of the existing hub for later incremental logic. #}
    distinct_target_hashkeys AS (

        SELECT
            {{ hashkey }}
        FROM {{ this }}

    ),
    {%- if ns.has_rsrc_static_defined -%}
        {% for source_model in source_models %}
         {# Create a query with a rsrc_static column with each rsrc_static for each source model. #}
            {%- set source_number = source_model.id | string -%}
            {%- set rsrc_statics = ns.source_models_rsrc_dict.id -%}

            {{log('rsrc_statics: '~rsrc_statics, true) }}

            {%- set rsrc_static_query_source -%}
                {%- for rsrc_static in rsrc_statics -%}
                    SELECT t.{{ src_rsrc }},
                    '{{ rsrc_static }}' AS rsrc_static
                    FROM {{ this }} t
                    WHERE {{ src_rsrc }} like '{{ rsrc_static }}'
                    {%- if not loop.last %}
                        UNION ALL
                    {% endif -%}
                {%- endfor -%}
            {% endset %}

            rsrc_static_{{ source_number }} AS (
                {%- for rsrc_static in rsrc_statics -%}
                    SELECT 
                    t.*,
                    '{{ rsrc_static }}' AS rsrc_static
                    FROM {{ this }} t
                    WHERE {{ src_rsrc }} like '{{ rsrc_static }}'
                    {%- if not loop.last %}
                        UNION ALL
                    {% endif -%}
                {%- endfor -%}
                {%- set ns.last_cte = "rsrc_static_{}".format(source_number) -%}
            ),
        
            {%- if execute -%}
                {%- set rsrc_static_result = run_query(rsrc_static_query_source) -%}
            {%- endif -%}
            {%- set source_in_target = true -%}

            {% if not rsrc_static_result %}
                {%- set source_in_target = false -%}
            {% endif %}

            {%- do ns.source_included_before.update({source_model.id: source_in_target}) -%}

        {% endfor -%}

        {%- if source_models | length > 1 %}

        rsrc_static_union AS (
            {#  Create one unionized table over all sources. It will be the same as the already existing
                hub, but extended by the rsrc_static column. #}
            {% for source_model in source_models %}
            {%- set source_number = source_model.id | string -%}

            SELECT rsrc_static_{{ source_number }}.* FROM rsrc_static_{{ source_number }}

            {%- if not loop.last %}
            UNION ALL
            {% endif -%}
            {%- endfor %}
            {%- set ns.last_cte = "rsrc_static_union" -%}
        ),

        {%- endif %}

        max_ldts_per_rsrc_static_in_target AS (
        {# Use the previously created CTE to calculate the max load date timestamp per rsrc_static. #}
            SELECT
                rsrc_static,
                MAX({{ src_ldts }}) as max_ldts
            FROM {{ ns.last_cte }}
            WHERE {{ src_ldts }} != {{ datavault4dbt.string_to_timestamp(timestamp_format, end_of_all_times) }}
            GROUP BY rsrc_static

        ),
    {%- endif %}
{% endif -%}

{% for source_model in source_models %}

    {%- set source_number = source_model.id | string -%}

    {%- if ns.has_rsrc_static_defined -%}
        {%- set rsrc_statics = ns.source_models_rsrc_dict.id -%}
    {%- endif -%}

    {%- if 'hk_column' not in source_model.keys() %}
        {%- set hk_column = hashkey -%}
    {%- else -%}
        {%- set hk_column = source_model['hk_column'] -%}
    {% endif %}

    src_new_{{ source_number }} AS (

        SELECT
            {{ hk_column }} AS {{ hashkey }},
            {% for bk in source_model['bk_columns'] -%}
            {{ bk }},
            {% endfor -%}

            {{ src_ldts }},
            {{ src_rsrc }}
        FROM {{ ref(source_model.name) }} src

    {%- if is_incremental() and ns.has_rsrc_static_defined and ns.source_included_before[source_number] %}
        INNER JOIN max_ldts_per_rsrc_static_in_target max ON
        ({%- for rsrc_static in rsrc_statics -%}
            max.rsrc_static = '{{ rsrc_static }}'
            {%- if not loop.last -%} OR
            {% endif -%}
        {%- endfor %})
        WHERE src.{{ src_ldts }} > max.max_ldts
    {%- endif %}

         {%- set ns.last_cte = "src_new_{}".format(source_number) %}

    ),
{%- endfor -%}

{%- if source_models | length > 1 %}

source_new_union AS (

    {%- for source_model in source_models -%}

    {%- set source_number = source_model.id | string -%}

    SELECT
        {{ hashkey }},

        {% for bk in source_model['bk_columns'] -%}
            {{ bk }} AS {{ business_keys[loop.index - 1] }},
        {% endfor -%}

        {{ src_ldts }},
        {{ src_rsrc }}
    FROM src_new_{{ source_number }}

    {%- if not loop.last %}
    UNION ALL
    {% endif -%}

    {%- endfor -%}

    {%- set ns.last_cte = 'source_new_union' -%}

),

{%- endif %}

earliest_hk_over_all_sources AS (

    {#- Deduplicate the unionized records again to only insert the earliest one. #}
    SELECT
        lcte.*
    FROM {{ ns.last_cte }} AS lcte

    QUALIFY ROW_NUMBER() OVER (PARTITION BY {{ hashkey }} ORDER BY {{ src_ldts }}) = 1

    {%- set ns.last_cte = 'earliest_hk_over_all_sources' -%}

),

records_to_insert AS (
    {#- Select everything from the previous CTE, if incremental filter for hashkeys that are not already in the hub. #}
    SELECT
        {{ datavault4dbt.print_list(final_columns_to_select) }}
    FROM {{ ns.last_cte }}

    {%- if is_incremental() %}
    WHERE {{ hashkey }} NOT IN (SELECT * FROM distinct_target_hashkeys)
    {% endif -%}
)

SELECT * FROM records_to_insert

{%- endmacro -%}
