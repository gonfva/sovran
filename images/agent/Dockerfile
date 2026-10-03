FROM public.ecr.aws/docker/library/python:3.12-alpine

WORKDIR /app
COPY jail.py tools.py model_client.py loop.py app.py ./

ENV PORT=8080
ENV HOST=0.0.0.0
ENV WORKSPACE=/workspace
EXPOSE 8080

# No AWS SDK/CLI by design. Writes go to the shared /workspace volume.
CMD ["python", "-u", "app.py"]
