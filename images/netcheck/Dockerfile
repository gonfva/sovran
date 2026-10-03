# One-shot network probe image for Phase 1 exit criteria (agent subnet).
FROM public.ecr.aws/docker/library/alpine:3.20
RUN apk add --no-cache curl
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
