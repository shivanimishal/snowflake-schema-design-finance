-- ============================================================
-- Snowflake Finance Analytics — Cloud DW Schema
-- Author: Shivani Mishal
-- Context: Migrating from flat Excel analytical data store to
-- a governed Snowflake data lake — mirrors current GS project
-- ============================================================

-- ── DATABASE SETUP ───────────────────────────────────────────
-- Snowflake organises data in: Account > Database > Schema > Table
-- Creating these explicitly ensures the schema is portable and documented
-- IF NOT EXISTS used consistently throughout setup — safe to re-run without data loss
CREATE DATABASE IF NOT EXISTS finance_analytics;
USE DATABASE finance_analytics;
CREATE SCHEMA IF NOT EXISTS procurement;
USE SCHEMA procurement;

-- ── DIMENSION: VENDOR ────────────────────────────────────────
-- AUTOINCREMENT: Snowflake generates surrogate keys automatically
-- Surrogate keys (vendor_sk) are used for joins instead of natural keys (vendor_id)
-- WHY: If vendor_id changes (business rekey), surrogate key stays stable
-- This protects fact table joins from business key changes — SCD best practice
-- FIX: CLUSTER BY removed from dim_vendor — clustering is only beneficial on
-- large fact tables scanned millions of times. Dimension tables are small
-- (hundreds/thousands of rows) and fit in a handful of micro-partitions regardless.
-- Clustering a dim table consumes Snowflake credits for zero query benefit.
CREATE TABLE IF NOT EXISTS dim_vendor (
    vendor_sk                NUMBER AUTOINCREMENT PRIMARY KEY,   -- surrogate key
    vendor_id                VARCHAR(20)  NOT NULL UNIQUE,       -- natural/business key
    vendor_name              VARCHAR(200) NOT NULL,
    vendor_category          VARCHAR(100),
    -- FIX: NOT NULL retained — consistent with fact_invoice.region (also NOT NULL below)
    region                   VARCHAR(20)  NOT NULL,
    country                  VARCHAR(100),
    payment_terms_days       INT,
    -- FIX: renamed from is_epd_eligible — EPD terminology replaced with discounting
    -- throughout schema to match updated project naming convention
    is_discounting_eligible  BOOLEAN      DEFAULT FALSE,
    -- NOTE: Snowflake parses CHECK constraints but does not enforce them at DML time
    -- They are included here as self-documenting governance controls
    platform                 VARCHAR(100) CHECK (platform IN
                             ('SAP Ariba','Coupa','Tungsten Network','Legacy ERP','Other')),
    -- TIMESTAMP_NTZ: timestamp with no timezone — standard for finance systems
    -- where UTC is the single source of truth
    created_at               TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP
);
-- FIX: CREATE OR REPLACE TABLE replaced with CREATE TABLE IF NOT EXISTS
-- throughout — consistent with the IF NOT EXISTS approach used for DATABASE
-- and SCHEMA above. OR REPLACE silently drops and recreates the table,
-- deleting all existing data — dangerous in any environment beyond initial dev.

-- ── DIMENSION: DATE ──────────────────────────────────────────
-- Pre-populated date spine: loaded once with all dates for 5+ years
-- WHY this exists: avoids calling DATEPART(), YEAR(), MONTH() in every query
-- Those functions prevent partition pruning — a common Snowflake performance issue
-- With a date dim, analysts just join to it and filter on year=2024, quarter=2
CREATE TABLE IF NOT EXISTS dim_date (
    date_key            DATE         PRIMARY KEY,
    year                INT,
    quarter             INT,
    month               INT,
    month_name          VARCHAR(20),
    week_of_year        INT,
    day_of_week         INT,
    is_weekend          BOOLEAN,
    is_month_end        BOOLEAN,
    is_quarter_end      BOOLEAN
);

-- ── FACT: INVOICE ────────────────────────────────────────────
-- GENERATED ALWAYS AS: Snowflake computes these columns automatically
-- from stored base columns — no manual calculation needed
-- WHY generated columns: prevents inconsistency if someone updates paid_date_key
-- but forgets to recalculate days_to_pay manually
-- CLUSTER BY (invoice_date_key, region): dual cluster because most queries
-- filter on BOTH date range AND region simultaneously
CREATE TABLE IF NOT EXISTS fact_invoice (
    invoice_sk          NUMBER AUTOINCREMENT PRIMARY KEY,
    invoice_id          VARCHAR(30)  NOT NULL UNIQUE,
    -- References use surrogate keys — not natural keys — for SCD safety
    vendor_sk           NUMBER       REFERENCES dim_vendor(vendor_sk),
    invoice_date_key    DATE         REFERENCES dim_date(date_key),
    -- FIX: REFERENCES dim_date(date_key) added to due_date_key and paid_date_key
    -- Previously only invoice_date_key had a FK reference to dim_date — inconsistent
    -- All three date columns should enforce the same referential integrity rule
    -- paid_date_key remains nullable — unpaid invoices have no paid date yet
    due_date_key        DATE         REFERENCES dim_date(date_key),
    paid_date_key       DATE         REFERENCES dim_date(date_key),
    amount_usd          NUMBER(18,2),   -- 18 digits: handles multi-billion amounts
    -- FIX: valid status values documented explicitly
    -- NOTE: Snowflake parses CHECK constraints but does not enforce them at DML time
    -- Included as a governance control and self-documentation
    status              VARCHAR(30)  CHECK (status IN
                        ('Paid','Approved','Pending','Disputed','Rejected')),
    -- FIX: NOT NULL added to region — consistent with dim_vendor.region (also NOT NULL)
    -- Previously region was nullable in fact_invoice but NOT NULL in dim_vendor
    region              VARCHAR(20)  NOT NULL,
    invoice_type        VARCHAR(50),
    -- DATEDIFF: Snowflake built-in — calculates days between two dates
    -- GENERATED ALWAYS AS means Snowflake recomputes this if dates change
    -- Returns NULL when paid_date_key is NULL (unpaid invoices) — correct behaviour
    days_to_pay         INT          GENERATED ALWAYS AS
                        (DATEDIFF('day', invoice_date_key, paid_date_key)),
    -- FIX: comment updated — was "core EPD metric", now "core discounting metric"
    -- TRUE if paid before due date — core discounting metric
    -- Returns NULL when either date is NULL — correct behaviour for unpaid invoices
    is_early_payment    BOOLEAN      GENERATED ALWAYS AS
                        (paid_date_key < due_date_key)
)
CLUSTER BY (invoice_date_key, region);

-- ── SNOWFLAKE-SPECIFIC: QUALIFY CLAUSE ───────────────────────
-- QUALIFY is a Snowflake-native alternative to wrapping a window function
-- in a subquery. Standard SQL would require: SELECT * FROM (...) WHERE rn = 1
-- QUALIFY makes this inline — cleaner, easier to read, and often faster
-- Business use: Get the largest invoice per vendor in the last 90 days
SELECT
    vendor_sk,
    invoice_id,
    amount_usd,
    invoice_date_key
FROM fact_invoice
WHERE invoice_date_key >= DATEADD('day', -90, CURRENT_DATE)   -- last 90 days
-- ROW_NUMBER() assigns 1 to the highest amount per vendor
-- QUALIFY keeps only rank-1 rows — one per vendor
QUALIFY ROW_NUMBER() OVER (
    PARTITION BY vendor_sk
    ORDER BY amount_usd DESC) = 1;

-- ── SNOWFLAKE-SPECIFIC: TIME TRAVEL ──────────────────────────
-- Snowflake retains historical versions of your data for up to 90 days
-- AT (OFFSET => -3600) means: show me this table as it was 1 hour ago
-- Business use: Debug a pipeline load that corrupted data — roll back and inspect
-- This is a governance and audit feature — important in a regulated environment
-- NOTE: requires the table to have existed for at least 1 hour before running
SELECT * FROM fact_invoice AT (OFFSET => -3600);   -- 3600 seconds = 1 hour ago
