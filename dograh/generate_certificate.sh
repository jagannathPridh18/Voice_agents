#!/bin/bash
mkdir -p certs
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout certs/local.key \
  -out certs/local.crt \
  -days 365 \
  -subj "/CN=183.82.113.118"
