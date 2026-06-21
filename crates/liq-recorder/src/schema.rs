//! Database schema contract checks.

use sqlx::PgPool;

/// Expected database column contract.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ColumnContract {
    /// Table name.
    pub table: &'static str,
    /// Column name.
    pub column: &'static str,
    /// Postgres `information_schema` data type.
    pub data_type: &'static str,
    /// Whether the column is nullable.
    pub nullable: bool,
}

/// Schema contract violation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SchemaViolation {
    /// Table name.
    pub table: String,
    /// Column name.
    pub column: String,
    /// Human-readable problem.
    pub problem: String,
}

/// Validate the strategy-facing schema contract.
///
/// # Errors
///
/// Returns an error when schema inspection query fails.
pub async fn assert_schema_contract(pool: &PgPool) -> Result<Vec<SchemaViolation>, sqlx::Error> {
    let mut violations = Vec::new();
    for expected in expected_contracts() {
        let actual = sqlx::query_as::<_, (String, String)>(
            r"
            SELECT data_type, is_nullable
            FROM information_schema.columns
            WHERE table_schema = 'public'
              AND table_name = $1
              AND column_name = $2
            ",
        )
        .bind(expected.table)
        .bind(expected.column)
        .fetch_optional(pool)
        .await?;

        match actual {
            Some((data_type, is_nullable)) => {
                let nullable = is_nullable == "YES";
                if data_type != expected.data_type || nullable != expected.nullable {
                    violations.push(SchemaViolation {
                        table: expected.table.to_owned(),
                        column: expected.column.to_owned(),
                        problem: format!(
                            "expected {} nullable={}, got {} nullable={}",
                            expected.data_type, expected.nullable, data_type, nullable
                        ),
                    });
                }
            }
            None => violations.push(SchemaViolation {
                table: expected.table.to_owned(),
                column: expected.column.to_owned(),
                problem: "missing column".to_owned(),
            }),
        }
    }

    Ok(violations)
}

fn expected_contracts() -> &'static [ColumnContract] {
    &[
        ColumnContract {
            table: "raw_source_events",
            column: "payload",
            data_type: "jsonb",
            nullable: false,
        },
        ColumnContract {
            table: "raw_source_events",
            column: "payload_sha256",
            data_type: "text",
            nullable: false,
        },
        ColumnContract {
            table: "liquidation_events",
            column: "event_id",
            data_type: "uuid",
            nullable: false,
        },
        ColumnContract {
            table: "liquidation_events",
            column: "price",
            data_type: "numeric",
            nullable: false,
        },
        ColumnContract {
            table: "liquidation_events",
            column: "quantity",
            data_type: "numeric",
            nullable: false,
        },
        ColumnContract {
            table: "liquidation_events",
            column: "notional_usd",
            data_type: "numeric",
            nullable: false,
        },
        ColumnContract {
            table: "archive_manifests",
            column: "parquet_schema_version",
            data_type: "integer",
            nullable: false,
        },
        ColumnContract {
            table: "archive_manifests",
            column: "canonical_deletion_watermark",
            data_type: "timestamp with time zone",
            nullable: true,
        },
        ColumnContract {
            table: "replay_runs",
            column: "input_hash",
            data_type: "text",
            nullable: false,
        },
    ]
}
