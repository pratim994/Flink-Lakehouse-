-- Idempotent Iceberg DDL bootstrap only; this file starts no streaming writers.
USE CATALOG lake;
CREATE DATABASE IF NOT EXISTS demo;
USE demo;

-- Iceberg v2 equality deletes support CDC UPDATE/DELETE by primary key.
CREATE TABLE IF NOT EXISTS products (
  id INT,
  sku STRING,
  name STRING,
  PRIMARY KEY (id) NOT ENFORCED
) WITH ('format-version' = '2', 'write.upsert.enabled' = 'true');

CREATE TABLE IF NOT EXISTS sales (
  id BIGINT,
  product_id INT,
  qty INT,
  price DECIMAL(10,2),
  sale_ts TIMESTAMP(3),
  PRIMARY KEY (id) NOT ENFORCED
) WITH ('format-version' = '2', 'write.upsert.enabled' = 'true');
