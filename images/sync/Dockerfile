FROM public.ecr.aws/docker/library/python:3.12-alpine

WORKDIR /app
RUN pip install --no-cache-dir boto3==1.35.99
COPY sync_down.py sync_up.py ./

ENV WORKSPACE=/workspace
# Default command overridden per ECS container.
CMD ["python", "-u", "sync_down.py"]
