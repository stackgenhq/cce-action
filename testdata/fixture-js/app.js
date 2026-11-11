// Minimal JavaScript cloud-SDK fixture for the cce-action self-test.
// Mirrors the AWS SDK v3 pattern covered by cce's analyzer testdata
// (pkg/analyzer/testdata/aws.ec2.js): client + command + send, which the
// mapper resolves to @aws-sdk/client-s3.S3Client.send (provider AWS).

import { PutObjectCommand, S3Client } from "@aws-sdk/client-s3";

export const uploadDemoFile = async () => {
  const client = new S3Client({ region: "us-east-1" });
  const command = new PutObjectCommand({
    Bucket: "demo-bucket",
    Key: "hello.txt",
    Body: "hello from cce-action self-test",
  });
  const response = await client.send(command);
  console.log(`uploaded with ETag ${response.ETag}`);
  return response;
};

uploadDemoFile().catch((err) => {
  console.error(err);
  process.exit(1);
});
