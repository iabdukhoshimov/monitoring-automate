# Elasticsearch with repository-s3 plugin pre-installed.
# Used for local dev only — production ES is managed separately.
FROM docker.elastic.co/elasticsearch/elasticsearch:8.13.0

# Bake in the S3 plugin so the image is ready to use immediately
RUN elasticsearch-plugin install --batch repository-s3

COPY entrypoint.sh /usr/local/bin/es-entrypoint.sh
RUN chmod +x /usr/local/bin/es-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/es-entrypoint.sh"]
