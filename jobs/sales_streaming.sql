SET 'execution.runtime-mode' = 'streaming';
SET 'execution.checkpointing.interval' = '30s';
SET 'pipeline.name' = 'cdc-sales-to-iceberg';

USE CATALOG lake;
USE demo;

CREATE TEMPORARY TABLE mysql_sales_stream (
  id BIGINT,
  product_id INT,
  qty INT,
  price DECIMAL(10,2),
  sale_ts TIMESTAMP(3),
  PRIMARY KEY (id) NOT ENFORCED
) WITH (
  'connector' = 'mysql-cdc',
  'hostname' = 'mysql',
  'port' = '3306',
  'username' = 'root',
  'password' = '${MYSQL_ROOT_PASSWORD}',
  'database-name' = 'appdb',
  'table-name' = 'sales',
  'scan.incremental.snapshot.enabled' = 'true',
  'scan.startup.mode' = 'initial'
);

INSERT INTO sales SELECT id, product_id, qty, price, sale_ts FROM mysql_sales_stream;
