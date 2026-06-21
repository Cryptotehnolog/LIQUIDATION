//! Database migration runner.

use sqlx::{PgPool, migrate::Migrator};

static MIGRATOR: Migrator = sqlx::migrate!("./migrations");

/// Run embedded migrations.
///
/// # Errors
///
/// Returns an error when a migration cannot be applied.
pub async fn run(pool: &PgPool) -> Result<(), sqlx::migrate::MigrateError> {
    MIGRATOR.run(pool).await
}
