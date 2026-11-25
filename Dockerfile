FROM flink:1.19.3@sha256:1bf0a2e91e8640900914dfd54ed605776778b1d978257e72438547004e49c6a9
WORKDIR /opt/flink

# Ensure freshly created named state volumes inherit write access for Flink.
RUN mkdir -p /opt/flink/checkpoints /opt/flink/state \
    && chown -R flink:flink /opt/flink/checkpoints /opt/flink/state

# --- Required JARs only (no Hadoop/S3A) ---
# MySQL CDC (works on 1.19)
ADD https://repo1.maven.org/maven2/org/apache/flink/flink-sql-connector-mysql-cdc/3.2.0/flink-sql-connector-mysql-cdc-3.2.0.jar /opt/flink/lib/
# Iceberg Flink runtime for Flink 1.19 (updated to 1.10.0)
ADD https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-flink-runtime-1.19/1.10.0/iceberg-flink-runtime-1.19-1.10.0.jar /opt/flink/lib/
# Iceberg AWS bundle (S3FileIO) - updated to 1.10.0
ADD https://repo1.maven.org/maven2/org/apache/iceberg/iceberg-aws-bundle/1.10.0/iceberg-aws-bundle-1.10.0.jar /opt/flink/lib/
# MySQL JDBC (for Iceberg JDBC catalog)
ADD https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/8.4.0/mysql-connector-j-8.4.0.jar /opt/flink/lib/
# Minimal Hadoop dependencies for S3FileIO
ADD https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-client-api/3.3.6/hadoop-client-api-3.3.6.jar /opt/flink/lib/
ADD https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-client-runtime/3.3.6/hadoop-client-runtime-3.3.6.jar /opt/flink/lib/

# Permissions
RUN chmod 644 /opt/flink/lib/*.jar
