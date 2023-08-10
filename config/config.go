// Copyright 2022 The TVL Contributors
// SPDX-License-Identifier: Apache-2.0

// Package config implements structures to store Nixery's configuration at
// runtime as well as the logic for instantiating this configuration from the
// environment.
package config

import (
	"os"

	log "github.com/sirupsen/logrus"
)

func getConfig(key, desc, def string) string {
	value := os.Getenv(key)
	if value == "" && def == "" {
		log.WithFields(log.Fields{
			"option":      key,
			"description": desc,
		}).Fatal("missing required configuration envvar")
	} else if value == "" {
		return def
	}

	return value
}

// Backend represents the possible storage backend types
type Backend int

const (
	GCS = iota
	S3
	FileSystem
)

// Config holds the Nixery configuration options.
type Config struct {
	Port              string  // Port on which to launch HTTP server
	Flake             string  // Source for Nix package set
	Timeout           string  // Timeout for a single Nix builder (seconds)
	WebDir            string  // Directory with static web assets
	PopUrl            string  // URL to the Nix package popularity count
	Backend           Backend // Storage backend to use for Nixery
	NixCacheUploadURL string  // https://nixos.org/manual/nix/stable/package-management/s3-substituter.html
}

func FromEnv() (Config, error) {
	var b Backend
	switch os.Getenv("NIXERY_STORAGE_BACKEND") {
	case "gcs":
		b = GCS
	case "s3":
		b = S3
	case "filesystem":
		b = FileSystem
	default:
		log.Fatal("NIXERY_STORAGE_BACKEND must be set to a supported value (gcs, s3, or filesystem)")
	}

	return Config{
		Port:              getConfig("PORT", "HTTP port", ""),
		Flake:             getConfig("NIXERY_FLAKE", "Source flake to use", "nixpkgs"),
		Timeout:           getConfig("NIX_TIMEOUT", "Nix builder timeout", "60"),
		WebDir:            getConfig("WEB_DIR", "Static web file dir", "./web"),
		PopUrl:            os.Getenv("NIX_POPULARITY_URL"),
		Backend:           b,
		NixCacheUploadURL: os.Getenv("NIX_CACHE_UPLOAD_URL"),
	}, nil
}
