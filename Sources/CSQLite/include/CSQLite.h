// Hardening for untrusted SQLite databases, in C because sqlite3_db_config is variadic.
#ifndef AMEYA_CSQLITE_H
#define AMEYA_CSQLITE_H

/// Configures an open connection (a `sqlite3 *`) for a database from an unknown source:
/// defensive mode on, the schema untrusted (so views, triggers, defaults and generated columns
/// can only use harmless functions), triggers, views, extension loading and the fts3_tokenizer
/// function off. Returns 0 when every setting was applied.
int ameya_sqlite_harden(void *db);

#endif
