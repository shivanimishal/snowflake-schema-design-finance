# Snowflake Schema Design — Finance Analytics Migration

## Business Problem
A corporate analytics team is migrating from flat, Excel-based analytical
data sources to a governed Snowflake data lake. This project documents the
schema design, architecture decisions, and Snowflake-specific implementation
patterns for the new analytical layer — including the rationale behind each
structural choice.

## Business Skills Demonstrated
- **Architecture decision-making:** Every design choice is documented with
  business justification, not just technical description
- **Governance thinking:** Surrogate keys, generated columns, and clustering
  reflect production-standard data engineering — not tutorial-level design
- **Migration strategy:** Schema designed with the specific constraints of
  a 100+ stakeholder self-service environment in mind

## Technical Skills Demonstrated
- Snowflake DDL: AUTOINCREMENT, GENERATED ALWAYS AS, CLUSTER BY
- Snowflake-specific: QUALIFY clause, Time Travel, TIMESTAMP_NTZ
- Star schema design with surrogate key pattern
- Clustering key strategy for query performance

## Architecture: Why Star Schema Over Snowflake Schema?
| Factor | Decision | Rationale |
|--------|----------|-----------|
| Stakeholder SQL ability | Star schema | Fewer joins, accessible to non-engineers |
| BI tool performance | Star schema | Power BI + Tableau optimised for stars |
| Query concurrency (100+ users) | Star schema | Simpler models handle concurrency better |
| SCD requirement | Surrogate keys | Protects fact joins if business keys change |

## Key Design Decisions
**Surrogate keys:** Fact tables join on auto-generated integer keys rather than
business identifiers. This insulates the model from upstream key changes.

**Generated columns:** days_to_pay and is_early_payment auto-compute from
stored dates — eliminating inconsistency risk if base values are updated.

**Clustering keys:** Both fact tables cluster on date + region — matching the
dominant filter pattern in procurement reporting.

**QUALIFY over subqueries:** Snowflake-native clause used for window function
row filtering — cleaner and often more performant than wrapping in a subquery.

**Discounting programme:** is_discounting_eligible flags vendors enrolled in
the discounting programme. is_early_payment (generated column)
tracks whether each invoice was settled before its due date — the core metric
for measuring discounting programme effectiveness.


## Tools
Snowflake SQL  |  Author: Shivani Mishal
