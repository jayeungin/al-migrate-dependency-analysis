FROM registry.access.redhat.com/ubi9/python-312:latest AS builder

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM registry.access.redhat.com/ubi9/python-312:latest

COPY --from=builder /opt/app-root /opt/app-root

COPY app/ app/
COPY mappings/ mappings/
COPY run.py .

EXPOSE 8000

CMD ["python", "run.py"]
