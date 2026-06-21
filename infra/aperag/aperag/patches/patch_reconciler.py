from pathlib import Path


RECONCILER = Path("/app/aperag/tasks/reconciler.py")


def replace_once(source: str, old: str, new: str, label: str) -> str:
    count = source.count(old)
    if count != 1:
        raise RuntimeError(f"Expected exactly one occurrence for {label}, found {count}")
    return source.replace(old, new, 1)


source = RECONCILER.read_text(encoding="utf-8")

if "pg_advisory_xact_lock(hashtext(:document_id))" in source:
    print("LIQUIDATION ApeRAG reconciler patch already applied")
    raise SystemExit(0)

source = replace_once(
    source,
    "from sqlalchemy import and_, or_, select, update",
    "from sqlalchemy import and_, or_, select, text, update",
    "sqlalchemy text import",
)

source = replace_once(
    source,
    '''    @staticmethod
    def _update_document_status(document_id: str, session: Session):
''',
    '''    @staticmethod
    def _lock_document_status_update(document_id: str, session: Session):
        """Serialize index callback status updates for the same document.

        VECTOR and FULLTEXT callbacks can finish in parallel. Without a
        per-document transaction lock, both callbacks may calculate the overall
        document status before seeing the other callback commit, leaving
        Document.status stuck at RUNNING while all indexes are ACTIVE.
        """
        session.execute(
            text("SELECT pg_advisory_xact_lock(hashtext(:document_id))"),
            {"document_id": document_id},
        )

    @staticmethod
    def _update_document_status(document_id: str, session: Session):
''',
    "document status lock helper",
)

source = replace_once(
    source,
    '''        for session in get_sync_session():
            # Use atomic update with version validation
''',
    '''        for session in get_sync_session():
            IndexTaskCallbacks._lock_document_status_update(document_id, session)
            # Use atomic update with version validation
''',
    "created callback lock",
)

source = replace_once(
    source,
    '''        for session in get_sync_session():
            # Use atomic update with state validation
''',
    '''        for session in get_sync_session():
            IndexTaskCallbacks._lock_document_status_update(document_id, session)
            # Use atomic update with state validation
''',
    "failed callback lock",
)

source = replace_once(
    source,
    '''        for session in get_sync_session():
            # Delete the record entirely
''',
    '''        for session in get_sync_session():
            IndexTaskCallbacks._lock_document_status_update(document_id, session)
            # Delete the record entirely
''',
    "deleted callback lock",
)

RECONCILER.write_text(source, encoding="utf-8")
print("LIQUIDATION ApeRAG reconciler patch applied")
