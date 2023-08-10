// Copyright 2022 The TVL Contributors
// SPDX-License-Identifier: Apache-2.0

// Google Cloud Storage backend for Nixery.
package storage

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"time"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"

	log "github.com/sirupsen/logrus"
)

type S3Backend struct {
	bucket string
	client *minio.Client
}

// Constructs a new S3 bucket backend based on the configured
// environment variables.
func NewS3Backend() (*S3Backend, error) {
	bucket := os.Getenv("S3_BUCKET")
	if bucket == "" {
		return nil, fmt.Errorf("S3_BUCKET must be configured for S3 usage")
	}

	endpoint, err := url.Parse(os.Getenv("S3_ENDPOINT"))
	if err != nil {
		return nil, fmt.Errorf("S3_ENDPOINT should be an url: %w", err)
	}

	minioClient, err := minio.New(endpoint.Host, &minio.Options{
		Creds:  credentials.NewEnvAWS(),
		Secure: endpoint.Scheme == "https",
		Region: os.Getenv("AWS_REGION"),
	})
	if err != nil {
		return nil, fmt.Errorf("failed to setup S3 client: %w", err)
	}

	return &S3Backend{
		bucket: bucket,
		client: minioClient,
	}, nil
}

func (b *S3Backend) Name() string {
	return "S3 (" + b.bucket + ")"
}

func (b *S3Backend) Persist(ctx context.Context, path, contentType string, f Persister) (string, int64, error) {
	buf := new(bytes.Buffer)

	putObjectResult := make(chan struct {
		minio.UploadInfo
		error
	})

	hash, size, err := f(buf)
	go func() {
		info, err := b.client.PutObject(ctx, b.bucket, path, buf, -1, minio.PutObjectOptions{ContentType: contentType})
		putObjectResult <- struct {
			minio.UploadInfo
			error
		}{info, err}
	}()

	if err != nil {
		log.WithError(err).WithField("path", path).Error("failed to write to S3 upload buffer")
		return hash, size, err
	}

	info := <-putObjectResult

	if info.error != nil {
		log.WithError(err).WithField("path", path).Error("failed to complete S3 upload")
		return hash, size, err
	}

	return hash, size, nil
}

func (b *S3Backend) Fetch(ctx context.Context, path string) (io.ReadCloser, error) {
	_, err := b.client.StatObject(ctx, b.bucket, path, minio.StatObjectOptions{})
	if err != nil {
		return nil, err
	}
	return b.client.GetObject(ctx, b.bucket, path, minio.GetObjectOptions{})
}

// S3 does not have a Move operation so this copies and deletes instead.
func (b *S3Backend) Move(ctx context.Context, old, new string) error {
	if _, err := b.client.CopyObject(ctx, minio.CopyDestOptions{Bucket: b.bucket, Object: new}, minio.CopySrcOptions{Bucket: b.bucket, Object: old}); err != nil {
		return err
	}

	if err := b.client.RemoveObject(ctx, b.bucket, old, minio.RemoveObjectOptions{}); err != nil {
		log.WithError(err).WithFields(log.Fields{
			"new": new,
			"old": old,
		}).Warn("failed to delete renamed object")
		// this error should not break renaming and is not returned
	}

	return nil
}

func (b *S3Backend) Serve(digest string, r *http.Request, w http.ResponseWriter) error {
	log.WithField("layer", digest).Info("redirecting layer request to bucket")
	object := "layers/" + digest

	url, err := b.client.Presign(context.Background(), "GET", b.bucket, object, time.Hour, url.Values{})
	if err != nil {
		log.WithError(err).WithFields(log.Fields{
			"digest": digest,
			"bucket": b.bucket,
		}).Error("failed to sign S3 URL")

		return err
	}

	log.WithField("digest", digest).Info("redirecting blob request to S3 bucket")

	w.Header().Set("Location", url.String())
	w.WriteHeader(303)
	return nil
}
