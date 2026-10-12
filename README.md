# Demo DB Migration (Liquibase)

Liquibase changeset repo for the demo Order Service database (MySQL 8).
Migrations run on GitHub-hosted runners (`ubuntu-latest`), so the database
must be reachable from the public internet.

**Branch = environment.** Pushing to `dev`, `uat` or `main` migrates the
matching database automatically. Promotion is a merge: `dev → uat → main`.

| Branch | GitHub Environment | Database   |
|--------|--------------------|------------|
| `dev`  | `dev`              | `demoDev` |
| `uat`  | `uat`              | `demoUat` |
| `main` | `prd`              | `demoProd` |

## Project Structure

```
.
├── changes/
│   └── release-1.0.0/
│       ├── 0001_create_customers.sql
│       └── rollback.sql
├── .github/workflows/
│   ├── migrate.yml             # push to dev|uat|main -> migrate that environment
│   ├── run-migration.yml       # reusable job: validate, preview, update/rollback, history
│   └── pr-check.yml            # PR: update -> rollback -> update on a throwaway MySQL
├── changelog.yaml              # ONE changelog for every environment
├── docker-compose.yml          # Local MySQL for development
└── liquibase.properties        # Local CLI defaults (changelog file, log level)
```

In MySQL a schema *is* a database, so each environment is its own database on
the server (`demoDev`, `demoUat`, `demoProd`) and is selected purely by the
JDBC URL. The SQL files use plain object names and contain nothing environment
specific. The databases themselves are created by infrastructure, not by the
changelog.

MySQL DDL is **not transactional**: a changeset that fails half-way leaves the
earlier statements applied. The SQL files are therefore idempotent where MySQL
allows it (`CREATE TABLE IF NOT EXISTS`, `DROP ... IF EXISTS`, `INSERT IGNORE`,
`CREATE OR REPLACE VIEW`). `ALTER TABLE ... ADD COLUMN` has no `IF NOT EXISTS`
in MySQL, so those changesets rely on Liquibase running each changeset exactly
once; if one fails half-way, fix the database by hand before re-running.

## Configuration

Liquibase reads every setting from `LIQUIBASE_COMMAND_*` environment variables,
so no connection details live in the repo.

| Variable                           | Description                                           | Example                                                   |
|------------------------------------|-------------------------------------------------------|-----------------------------------------------------------|
| `LIQUIBASE_COMMAND_URL`            | JDBC connection string (database = environment)       | `jdbc:mysql://194.233.83.104:3306/demoDev` |
| `LIQUIBASE_COMMAND_USERNAME`       | Database username                                     | `migrator`                                                |
| `LIQUIBASE_COMMAND_PASSWORD`       | Database password                                     | `*****`                                                   |
| `LIQUIBASE_COMMAND_CHANGELOG_FILE` | Changelog to run (also set in `liquibase.properties`) | `changelog.yaml`                                          |
| `LIQUIBASE_CLASSPATH`              | Path to the MySQL JDBC driver jar (see below)         | `/tmp/mysql-connector-j-9.7.0.jar`                        |

### MySQL JDBC driver

Liquibase does not bundle MySQL Connector/J (GPL licence). The workflows
download it from Maven Central and point Liquibase at it through
`LIQUIBASE_CLASSPATH`. Locally do the same once:

```bash
curl -fsSL -o mysql-connector-j-9.7.0.jar \
  https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/9.7.0/mysql-connector-j-9.7.0.jar
export LIQUIBASE_CLASSPATH="$PWD/mysql-connector-j-9.7.0.jar"
```

### GitHub Environments (one-time setup)

Create three GitHub Environments named `dev`, `uat`, `prd` and set on each:

| Kind     | Name                         | Value                                                      |
|----------|------------------------------|------------------------------------------------------------|
| variable | `LIQUIBASE_COMMAND_URL`      | `jdbc:mysql://<host>:3306/demoDev / demoUat / demoProd`     |
| variable | `LIQUIBASE_COMMAND_USERNAME` | migration user                                             |
| secret   | `LIQUIBASE_COMMAND_PASSWORD` | database password                                          |

Add *required reviewers* on the `prd` environment to get a manual approval gate
before production migrations. The workflow fails fast with a clear message if
any of these is missing.

## Local Development

```bash
docker compose up -d        # MySQL on localhost:3307 (set MYSQL_PORT to change)

export LIQUIBASE_COMMAND_URL="jdbc:mysql://localhost:3307/demo"
export LIQUIBASE_COMMAND_USERNAME="demo"
export LIQUIBASE_COMMAND_PASSWORD="demo"
export LIQUIBASE_CLASSPATH="$PWD/mysql-connector-j-9.7.0.jar"   # see "MySQL JDBC driver"

liquibase validate
liquibase status --verbose
liquibase update
liquibase history
```

Apply up to a specific release only:

```bash
liquibase update-to-tag --tag=release-1.0.0
```

Roll back to a release (undoes everything after that tag):

```bash
liquibase rollback --tag=release-1.0.0
```

Without a local Liquibase install, use the official image and mount the driver:

```bash
docker run --rm --network demo-liquibase-main_default \
  -v "$PWD":/liquibase/changelog -w /liquibase/changelog \
  -v "$PWD/mysql-connector-j-9.7.0.jar":/liquibase/lib/mysql-connector-j.jar \
  -e LIQUIBASE_COMMAND_URL="jdbc:mysql://mysql:3306/demo" \
  -e LIQUIBASE_COMMAND_USERNAME=demo -e LIQUIBASE_COMMAND_PASSWORD=demo \
  liquibase/liquibase:4.33 --changelog-file=changelog.yaml update
```

## CI/CD Pipeline

### Pull request check (`pr-check.yml`)

Every PR into `dev`, `uat` or `main` that touches `changelog.yaml` or
`changes/**` runs on a GitHub-hosted runner with a throwaway MySQL 8.4 service:

1. `validate`
2. `tag baseline` on the empty database, then `update`
3. `rollback --tag=baseline` and check the database is empty again
4. `update` once more

This catches missing SQL files, broken SQL and rollbacks that do not undo their
change, before anything reaches a real database.

### Migration (`migrate.yml` → `run-migration.yml`)

A push to `dev`, `uat` or `main` (changelog, `changes/**` or the workflow files)
runs the reusable job against the branch's GitHub Environment:

1. Check the environment is fully configured.
2. `validate` and `status --verbose`.
3. `update-sql` (preview), then `update` to the head of the changelog.
4. `history`.

One migration runs at a time per branch (`concurrency` group); a running one is
never cancelled.

**Re-run / rollback:** open *Actions → Migrate database → Run workflow*, pick
the branch (which picks the environment), and either leave `rollback_tag` empty
to re-run the update or set it to a Liquibase tag (e.g. `release-1.0.0`) to roll
that environment back to it. The job previews the SQL with `rollback-sql`
before applying `rollback --tag`.

### Switching to a self-hosted runner

The runner is a single input of the reusable job, `runner` in
`.github/workflows/run-migration.yml` (default `ubuntu-latest`). To migrate
from a self-hosted runner (for example one that sits inside the database's
private network), pass the runner label from `migrate.yml`:

```yaml
jobs:
  migrate:
    uses: ./.github/workflows/run-migration.yml
    with:
      environment: ${{ github.ref_name == 'main' && 'prd' || github.ref_name }}
      rollback_tag: ${{ inputs.rollback_tag || '' }}
      runner: aks-runners        # label of your self-hosted runner / runner group
    secrets: inherit
```

Or change the `default:` of the `runner` input in `run-migration.yml` so every
caller uses it. Nothing else depends on the runner type: Java, Liquibase and the
JDBC driver are installed by the job itself, so the self-hosted runner only
needs network access to the database and to Maven Central / GitHub.

`pr-check.yml` is independent and always runs on `ubuntu-latest` because it
uses its own throwaway MySQL service container.

## Adding a New Release

1. Branch off `dev`, create the release folder and SQL files (plain object
   names, no database prefix):
   ```
   changes/release-1.1.0/
   ├── 0001_add_new_column.sql
   └── rollback.sql
   ```

2. Append a `changeSet` to `changelog.yaml`:
   ```yaml
   - changeSet:
       id: release-1.1.0
       author: demo
       changes:
         - tagDatabase:
             tag: release-1.1.0
         - sqlFile:
             path: changes/release-1.1.0/0001_add_new_column.sql
             dbms: mysql
             endDelimiter: ";"
             splitStatements: "true"
       rollback:
         - sqlFile:
             path: changes/release-1.1.0/rollback.sql
             dbms: mysql
             endDelimiter: ";"
             splitStatements: "true"
   ```

3. Open a PR into `dev`. The PR check must pass. Merge → dev is migrated.

4. Promote with PRs `dev → uat` and `uat → main`. Each merge migrates the
   corresponding environment.

5. **Never modify** an existing changeset. Fix forward with a new release, or
   roll back with *Run workflow* + `rollback_tag`.
