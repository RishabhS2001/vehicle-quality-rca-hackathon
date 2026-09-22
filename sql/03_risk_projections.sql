USE DATABASE VEHICLE_DB;
USE SCHEMA VEHICLE_SCHEMA;

-- Fleet-wide 30-day projection (rate-based, Poisson 95% CI)
CREATE OR REPLACE VIEW VW_OVERALL_RISK_PROJECTION AS
WITH daily_rate AS (
    SELECT
        SUM(FAILURE_COUNT) AS total_failures,
        COUNT(*) AS days_observed,
        SUM(FAILURE_COUNT) / COUNT(*) AS avg_daily_failures
    FROM DAILY_FAILURE_COUNTS
)
SELECT
    total_failures AS historical_failures,
    days_observed,
    avg_daily_failures,
    ROUND(avg_daily_failures * 30, 1) AS projected_30day_failures,
    ROUND(avg_daily_failures * 30 - 1.96 * SQRT(avg_daily_failures * 30), 1) AS lower_bound_95,
    ROUND(avg_daily_failures * 30 + 1.96 * SQRT(avg_daily_failures * 30), 1) AS upper_bound_95
FROM daily_rate;

-- Supplier-level projection (all suppliers, including zero-failure ones)
CREATE OR REPLACE VIEW VW_SUPPLIER_RISK_PROJECTION AS
WITH supplier_failures AS (
    SELECT
        s.ID AS supplier_id, s.NAME AS supplier_name, s.STATE AS supplier_state,
        COUNT(CASE WHEN v.DTC_ERROR_CODE > 0 THEN 1 END) AS historical_failures,
        59 AS days_observed
    FROM BATTERY_SUPPLIER s
    LEFT JOIN VW_VEHICLE_QUALITY v ON v.SUPPLIER_ID = s.ID
    GROUP BY s.ID, s.NAME, s.STATE
),
projected AS (
    SELECT supplier_id, supplier_name, supplier_state, historical_failures, days_observed,
        ROUND((historical_failures / days_observed) * 30, 1) AS projected_30day_failures
    FROM supplier_failures
)
SELECT supplier_id, supplier_name, supplier_state, historical_failures, projected_30day_failures,
    ROUND(projected_30day_failures - 1.96 * SQRT(NULLIF(projected_30day_failures,0)), 1) AS lower_bound_95,
    ROUND(projected_30day_failures + 1.96 * SQRT(NULLIF(projected_30day_failures,0)), 1) AS upper_bound_95,
    RANK() OVER (ORDER BY projected_30day_failures DESC) AS risk_rank
FROM projected
ORDER BY risk_rank;

-- Part-level projection (all parts, including zero-failure ones)
CREATE OR REPLACE VIEW VW_PART_RISK_PROJECTION AS
WITH unique_parts AS (
    SELECT * FROM (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY PART_NUMBER ORDER BY PART_ID) AS rn
        FROM PART_BATTERY
    ) WHERE rn = 1
),
part_failures AS (
    SELECT
        up.PART_NUMBER, s.NAME AS supplier_name, bt.NAME AS battery_type_name,
        COUNT(CASE WHEN v.DTC_ERROR_CODE > 0 THEN 1 END) AS historical_failures,
        59 AS days_observed
    FROM unique_parts up
    LEFT JOIN BATTERY_SUPPLIER s ON up.SUPPLIER = s.ID
    LEFT JOIN BATTERY_TYPE bt ON up.TYPE = bt.ID
    LEFT JOIN VW_VEHICLE_QUALITY v ON v.PART_NUMBER = up.PART_NUMBER
    GROUP BY up.PART_NUMBER, s.NAME, bt.NAME
),
projected AS (
    SELECT PART_NUMBER, supplier_name, battery_type_name, historical_failures, days_observed,
        ROUND((historical_failures / days_observed) * 30, 1) AS projected_30day_failures
    FROM part_failures
)
SELECT PART_NUMBER, supplier_name, battery_type_name, historical_failures, projected_30day_failures,
    ROUND(projected_30day_failures - 1.96 * SQRT(NULLIF(projected_30day_failures,0)), 1) AS lower_bound_95,
    ROUND(projected_30day_failures + 1.96 * SQRT(NULLIF(projected_30day_failures,0)), 1) AS upper_bound_95,
    RANK() OVER (ORDER BY projected_30day_failures DESC) AS risk_rank
FROM projected
ORDER BY risk_rank;

-- Battery chemistry-level projection (all types, including zero-failure ones)
CREATE OR REPLACE VIEW VW_BATTERY_TYPE_RISK_PROJECTION AS
WITH type_failures AS (
    SELECT
        bt.ID AS battery_type_id, bt.NAME AS battery_type_name,
        bc.ANODE, bc.CATHODE, bc.ELECTROLYTE,
        COUNT(CASE WHEN v.DTC_ERROR_CODE > 0 THEN 1 END) AS historical_failures,
        59 AS days_observed
    FROM BATTERY_TYPE bt
    LEFT JOIN BATTERY_COMPONENTS bc ON bt.ID = bc.BATTERY_TYPE
    LEFT JOIN VW_VEHICLE_QUALITY v ON v.BATTERY_TYPE_NAME = bt.NAME
    GROUP BY bt.ID, bt.NAME, bc.ANODE, bc.CATHODE, bc.ELECTROLYTE
),
projected AS (
    SELECT battery_type_id, battery_type_name, ANODE, CATHODE, ELECTROLYTE, historical_failures, days_observed,
        ROUND((historical_failures / days_observed) * 30, 1) AS projected_30day_failures
    FROM type_failures
)
SELECT battery_type_id, battery_type_name, ANODE, CATHODE, ELECTROLYTE, historical_failures, projected_30day_failures,
    ROUND(projected_30day_failures - 1.96 * SQRT(NULLIF(projected_30day_failures,0)), 1) AS lower_bound_95,
    ROUND(projected_30day_failures + 1.96 * SQRT(NULLIF(projected_30day_failures,0)), 1) AS upper_bound_95,
    RANK() OVER (ORDER BY projected_30day_failures DESC) AS risk_rank
FROM projected
ORDER BY risk_rank;