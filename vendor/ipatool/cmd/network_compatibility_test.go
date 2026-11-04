package cmd

import (
	"crypto/tls"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestNetworkCompatibility(t *testing.T) {
	original := http.DefaultTransport
	t.Cleanup(func() { http.DefaultTransport = original })
	t.Setenv("DUMPSHOP_TLS12", "")
	configureNetworkCompatibility()
	if http.DefaultTransport != original {
		t.Fatal("default transport changed without opt-in")
	}
	t.Setenv("DUMPSHOP_TLS12", "1")
	configureNetworkCompatibility()
	configured := http.DefaultTransport.(*http.Transport)
	t.Cleanup(configured.CloseIdleConnections)
	if configured == original || configured.TLSClientConfig.InsecureSkipVerify {
		t.Fatal("must clone transport and preserve certificate verification")
	}
	if configured.TLSClientConfig.MinVersion != tls.VersionTLS12 || configured.TLSClientConfig.MaxVersion != tls.VersionTLS12 {
		t.Fatal("TLS 1.2 compatibility mode not applied")
	}
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.TLS.Version != tls.VersionTLS12 {
			t.Error("request did not negotiate TLS 1.2")
		}
		w.WriteHeader(http.StatusNoContent)
	}))
	server.TLS = &tls.Config{MinVersion: tls.VersionTLS12, MaxVersion: tls.VersionTLS12}
	server.StartTLS()
	t.Cleanup(server.Close)
	client := &http.Client{Timeout: 3 * time.Second}
	if response, err := client.Get(server.URL); err == nil {
		response.Body.Close()
		t.Fatal("untrusted certificate was accepted")
	}
	trusted := configured.Clone()
	trusted.TLSClientConfig.RootCAs = server.Client().Transport.(*http.Transport).TLSClientConfig.RootCAs
	t.Cleanup(trusted.CloseIdleConnections)
	client.Transport = trusted
	response, err := client.Get(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	io.Copy(io.Discard, response.Body)
	response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		t.Fatal(response.Status)
	}
}
