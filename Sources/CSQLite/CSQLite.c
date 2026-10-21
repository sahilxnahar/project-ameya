#include "CSQLite.h"
#include <sqlite3.h>

int ameya_sqlite_harden(void *handle) {
    sqlite3 *db = (sqlite3 *)handle;
    if (db == 0) return 1;
    int failures = 0;
    failures += sqlite3_db_config(db, SQLITE_DBCONFIG_DEFENSIVE, 1, (int *)0) != SQLITE_OK;
    failures += sqlite3_db_config(db, SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0, (int *)0) != SQLITE_OK;
    failures += sqlite3_db_config(db, SQLITE_DBCONFIG_ENABLE_TRIGGER, 0, (int *)0) != SQLITE_OK;
    failures += sqlite3_db_config(db, SQLITE_DBCONFIG_ENABLE_VIEW, 0, (int *)0) != SQLITE_OK;
    // Builds without extension loading (Apple's) answer SQLITE_MISUSE here; it's off either way.
    (void)sqlite3_db_config(db, SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, 0, (int *)0);
    failures += sqlite3_db_config(db, SQLITE_DBCONFIG_ENABLE_FTS3_TOKENIZER, 0, (int *)0) != SQLITE_OK;
    return failures;
}
