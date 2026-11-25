SET 'execution.runtime-mode' = 'streaming';
SET 'execution.checkpointing.interval' = '30s';
SET 'pipeline.name' = 'cdc-products-to-iceberg';

USE CATALOG lake;
USE demo;

CREATE TEMPORARY TABLE mysql_products_stream (
  id INT,
  sku STRING,
  name STRING,
  PRIMARY KEY (id) NOT ENFORCED
) WITH (
  'connector' = 'mysql-cdc',
  'hostname' = 'mysql',
  'port' = '3306',
  'username' = 'root',
  'password' = '${MYSQL_ROOT_PASSWORD}',
  'database-name' = 'appdb',
  'table-name' = 'products',
  'scan.incremental.snapshot.enabled' = 'true',
  'scan.startup.mode' = 'initial'
);

INSERT INTO products SELECT id, sku, name FROM mysql_products_stream;
