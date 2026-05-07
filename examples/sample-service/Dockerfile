FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

RUN mkdir -p /var/log/sample-app
ENV APP_LOG_PATH=/var/log/sample-app/app.log

EXPOSE 9000
CMD ["python", "-u", "app.py"]
