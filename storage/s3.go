// Copyright 2022 The TVL Contributors
// SPDX-License-Identifier: Apache-2.0

// Google Cloud Storage backend for Nixery.
package storage

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/s3"
)

type S3Backend struct {
	bucket        string
	client        *s3.Client
	presignClient *s3.PresignClient
}

// Constructs a new S3 bucket backend based on the configured
// environment variables.
func NewS3Backend() (*S3Backend, error) {
	bucket := os.Getenv("S3_BUCKET")
	if bucket == "" {
		return nil, fmt.Errorf("S3_BUCKET must be configured for S3 usage")
	}

	ctx := context.Background()
	sdkConfig, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		return nil, err
	}
	s3Client := s3.NewFromConfig(sdkConfig, func(o *s3.Options) {
		o.UsePathStyle = os.Getenv("S3_USE_PATH_STYLE") == "true"
	})
	presignClient := s3.NewPresignClient(s3Client)

	return &S3Backend{
		bucket:        bucket,
		client:        s3Client,
		presignClient: presignClient,
	}, nil
}

func (b *S3Backend) Name() string {
	return "S3 (" + b.bucket + ")"
}

type putInfo struct {
	*s3.PutObjectOutput
	error
}

func (b *S3Backend) Persist(ctx context.Context, path, contentType string, f Persister) (string, int64, error) {
	buf := new(bytes.Buffer)

	putObjectResult := make(chan putInfo)

	hash, size, err := f(buf)
	go func() {
		info, err := b.client.PutObject(ctx, &s3.PutObjectInput{
			Bucket:      &b.bucket,
			Key:         &path,
			Body:        buf,
			ContentType: &contentType,
		})
		putObjectResult <- putInfo{info, err}
	}()

	if err != nil {
		slog.Error("failed to write to S3 upload buffer", "err", err, "path", path)
		return hash, size, err
	}

	info := <-putObjectResult

	if info.error != nil {
		slog.Error("failed to complete S3 upload", "err", err, "path", path)
		return hash, size, err
	}

	return hash, size, nil
}

func (b *S3Backend) Fetch(ctx context.Context, path string) (io.ReadCloser, error) {
	res, err := b.client.GetObject(ctx, &s3.GetObjectInput{
		Bucket: &b.bucket,
		Key:    &path,
	})
	if err != nil {
		return nil, err
	}
	return res.Body, nil
}

// S3 does not have a Move operation so this copies and deletes instead.
func (b *S3Backend) Move(ctx context.Context, old, new string) error {
	if _, err := b.client.CopyObject(ctx, &s3.CopyObjectInput{
		Bucket:     &b.bucket,
		CopySource: aws.String(fmt.Sprintf("%v/%v", b.bucket, old)),
		Key:        &new,
	}); err != nil {
		return err
	}

	waiter := s3.NewObjectExistsWaiter(b.client)
	if err := waiter.Wait(ctx, &s3.HeadObjectInput{
		Bucket: &b.bucket,
		Key:    &new,
	}, time.Minute); err != nil {
		return err
	}

	if _, err := b.client.DeleteObject(ctx, &s3.DeleteObjectInput{
		Bucket: &b.bucket,
		Key:    &old,
	}); err != nil {
		slog.Warn("failed to delete renamed object", "old", old, "new", new)
		// this error should not break renaming and is not returned
	}

	return nil
}

func (b *S3Backend) Serve(digest string, r *http.Request, w http.ResponseWriter) error {
	slog.Info("redirecting layer request to bucket", "layer", digest)
	object := "layers/" + digest

	request, err := b.presignClient.PresignGetObject(r.Context(), &s3.GetObjectInput{
		Bucket: &b.bucket,
		Key:    &object,
	})
	if err != nil {
		slog.Error("failed to sign S3 URL", "err", err, "digest", digest, "bucket", b.bucket)
		return err
	}

	slog.Info("redirecting blob request to S3 bucket", "digest", digest)

	w.Header().Set("Location", request.URL)
	w.WriteHeader(303)
	return nil
}
