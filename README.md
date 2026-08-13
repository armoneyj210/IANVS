Look inside Janus/Verify Migration:
docker exec -it therapy-postgres psql -U janus_migrator_svc -d therapy
Restart container:
docker start therapy-postgres
Show Schemas:
\dn
Show Tables:
\dt
Show Tables inside:
\dt clinical.*
\dt ingest.*
Describe a particular Table:
\d clinical.table-name
\d ingest.record_lineage
Exit:
\q
Run Migrations:
Get-Content .\db\migrations\'###_migration_file_name.sql' | docker exec -i therapy-postgres psql -v ON_ERROR_STOP=1 -U therapy_app -d therapy

Flyway inspect:
docker compose --profile tools run --rm flyway info
Flyway migrate:
docker compose --profile tools run --rm flyway migrate
Flyway validate:
docker compose --profile tools run --rm flyway validate 

Ruff check and fix:
uv run ruff check . --fix