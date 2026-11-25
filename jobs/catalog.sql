-- Executed only when the lake catalog is absent (Flink SQL Client lacks
-- CREATE CATALOG IF NOT EXISTS in the pinned Flink 1.19.3 parser).
CREATE CATALOG lake WITH (
  'type' = 'iceberg',
  'catalog-impl' = 'org.apache.iceberg.jdbc.JdbcCatalog',
  'uri' = 'jdbc:mysql://mysql:3306/iceberg_catalog',
  'jdbc.user' = 'root',
  'jdbc.password' = '${MYSQL_ROOT_PASSWORD}',
  'warehouse' = 's3://iceberg/warehouse',
  'io-impl' = 'org.apache.iceberg.aws.s3.S3FileIO',
  's3.endpoint' = 'http://minio:9000',
  's3.path-style-access' = 'true',
  's3.access-key-id' = '${MINIO_ROOT_USER}',
  's3.secret-access-key' = '${MINIO_ROOT_PASSWORD}',
  'client.region' = 'us-east-1'
);
