FROM public.ecr.aws/docker/library/python:3.12-alpine

WORKDIR /app
COPY app.py .

ENV PORT=8000
ENV HOST=0.0.0.0
EXPOSE 8000

USER nobody
CMD ["python", "-u", "app.py"]
