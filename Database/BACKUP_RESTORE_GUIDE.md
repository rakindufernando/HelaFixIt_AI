# HelaFixIt AI backup and restore guide

## MySQL Workbench export

1. Open MySQL Workbench.
2. Open Server and then Data Export.
3. Select `helafixit_ai`.
4. Select all tables.
5. Choose Export to Self-Contained File.
6. Save the file inside a protected local backup folder.
7. Start Export.
8. Record the backup file name, location, size and status in the System Admin backup function.

## MySQL command line export

```text
mysqldump -u root -p --routines --triggers --single-transaction helafixit_ai > helafixit_ai_backup.sql
```

## Restore using MySQL Workbench

1. Open Server and then Data Import.
2. Choose Import from Self-Contained File.
3. Select the backup SQL file.
4. Choose the target schema or create a clean `helafixit_ai` database.
5. Start Import.
6. Run `08_validation_queries_XAMPP.sql` after restoration.

## Seeded User Password Setup

Before importing `helafixit_ai_complete_setup.sql`, replace `REPLACE_WITH_VALID_PBKDF2_HASH_BEFORE_IMPORT` with a valid PBKDF2 SHA-256 password hash for a temporary password.

Do not store or commit the plaintext temporary password in this repository.

The seeded user accounts are configured to require a password change after the first successful sign in.

## Restore using command line

```text
mysql -u root -p helafixit_ai < helafixit_ai_backup.sql
```

## Prototype backup policy

Use a manual backup before major database or AI integration changes.

Keep at least a daily development backup while actively implementing the system.

Keep more than one backup so a damaged or incomplete file does not replace the only recovery copy.

Do not store public database backups containing real resident information in a public GitHub repository.
