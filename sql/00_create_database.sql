-- Run while connected to the maintenance DB:  psql -d postgres -f sql/00_create_database.sql
SELECT 'CREATE DATABASE queryme_library'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'queryme_library')
\gexec
