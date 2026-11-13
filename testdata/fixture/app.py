"""Minimal AWS SDK fixture so self-test can assert entitlements > 0."""

import boto3
import requests


def list_bucket_names():
    client = boto3.client("s3")
    return [bucket["Name"] for bucket in client.list_buckets().get("Buckets", [])]


def get_object_bytes(bucket: str, key: str) -> bytes:
    client = boto3.client("s3")
    response = client.get_object(Bucket=bucket, Key=key)
    return response["Body"].read()


def fetch_legacy_status(url: str) -> int:
    return requests.get(url, timeout=5).status_code
