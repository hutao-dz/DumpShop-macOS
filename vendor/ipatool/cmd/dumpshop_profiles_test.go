package cmd

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/majd/ipatool/v2/pkg/util/operatingsystem"
)

func TestDumpShopRegionalIsolation(t *testing.T) {
	home := t.TempDir()
	legacy := filepath.Join(home, ConfigDirectoryName)
	if err := os.MkdirAll(legacy, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(legacy, "cookies"), []byte("legacy-only"), 0600); err != nil {
		t.Fatal(err)
	}
	services := map[string]bool{}
	for _, profile := range []string{"cn", "us", "jp", "hk", "tw"} {
		t.Setenv("IPATOOL_PROFILE", profile)
		service := ipatoolKeychainServiceName()
		if services[service] {
			t.Fatalf("shared keychain service for %s", profile)
		}
		services[service] = true
		if profile == "cn" {
			if service != KeychainServiceName {
				t.Fatal("legacy CN service changed")
			}
			continue
		}
		base := filepath.Join(home, "profiles", profile)
		t.Setenv("XDG_STATE_HOME", base)
		directory, err := prepareStateDirectory(operatingsystem.New(), home)
		if err != nil || directory != filepath.Join(base, "ipatool") {
			t.Fatalf("regional path: %q, %v", directory, err)
		}
		if _, err := os.Stat(filepath.Join(directory, "cookies")); !os.IsNotExist(err) {
			t.Fatal("regional profile reused legacy cookies")
		}
	}
	if _, err := os.Stat(filepath.Join(legacy, "cookies")); err != nil {
		t.Fatal("legacy storage was moved")
	}
	t.Setenv("XDG_STATE_HOME", "")
	t.Setenv("XDG_DATA_HOME", "")
	if _, err := prepareStateDirectory(operatingsystem.New(), home); err == nil {
		t.Fatal("regional profile accepted default storage")
	}
}
