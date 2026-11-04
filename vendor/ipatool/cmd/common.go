package cmd

import (
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	nethttp "net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/byteness/keyring"
	cookiejar "github.com/juju/persistent-cookiejar"
	"github.com/majd/ipatool/v2/pkg/appstore"
	"github.com/majd/ipatool/v2/pkg/http"
	"github.com/majd/ipatool/v2/pkg/keychain"
	"github.com/majd/ipatool/v2/pkg/log"
	"github.com/majd/ipatool/v2/pkg/util"
	"github.com/majd/ipatool/v2/pkg/util/machine"
	"github.com/majd/ipatool/v2/pkg/util/operatingsystem"
	"github.com/rs/zerolog"
	"github.com/spf13/cobra"
)

var dependencies = Dependencies{}
var keychainPassphrase string

// ipatoolKeychainServiceName scopes the saved App Store session to the current
// regional profile. The default/CN profile deliberately keeps the historical
// service name so an existing one-account setup keeps working after upgrading.
func ipatoolKeychainServiceName() string {
	profile := strings.ToLower(strings.TrimSpace(os.Getenv("IPATOOL_PROFILE")))
	if profile == "" || profile == "cn" {
		return KeychainServiceName
	}
	var suffix strings.Builder
	for _, r := range profile {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') || r == '-' || r == '_' {
			suffix.WriteRune(r)
		}
	}
	if suffix.Len() == 0 {
		return KeychainServiceName
	}
	return KeychainServiceName + "." + suffix.String()
}

type Dependencies struct {
	Logger    log.Logger
	OS        operatingsystem.OperatingSystem
	Machine   machine.Machine
	CookieJar http.CookieJar
	Keychain  keychain.Keychain
	AppStore  appstore.AppStore
}

// newLogger returns a new logger instance.
func newLogger(format OutputFormat, verbose bool) log.Logger {
	var writer io.Writer

	switch format {
	case OutputFormatJSON:
		writer = zerolog.SyncWriter(os.Stdout)
	case OutputFormatText:
		writer = log.NewWriter()
	}

	return log.NewLogger(log.Args{
		Verbose: verbose,
		Writer:  writer,
	},
	)
}

// newCookieJar returns a new cookie jar instance.
func newCookieJar(stateDirectory string) http.CookieJar {
	return util.Must(cookiejar.New(&cookiejar.Options{
		Filename: filepath.Join(stateDirectory, CookieJarFileName),
	}))
}

// newKeychain returns a new keychain instance.
func newKeychain(stateDirectory string, interactive bool) keychain.Keychain {
	serviceName := ipatoolKeychainServiceName()
	ring := util.Must(openKeyring(keyring.Config{
		AllowedBackends: []keyring.BackendType{
			keyring.KeychainBackend,
			keyring.SecretServiceBackend,
			keyring.FileBackend,
		},
		ServiceName:              serviceName,
		KeychainTrustApplication: true,
		FileDir:                  stateDirectory,
		FilePasswordFunc: func(s string) (string, error) {
			if keychainPassphrase == "" && !interactive {
				return "", errors.New("keychain passphrase is required when not running in interactive mode; use the \"--keychain-passphrase\" flag")
			}

			if keychainPassphrase != "" {
				return keychainPassphrase, nil
			}

			path := strings.Split(s, " unlock ")[1]
			password, err := readPrompt(fmt.Sprintf("enter passphrase to unlock %s (this is separate from your Apple ID password): ", path), true)
			if err != nil {
				return "", fmt.Errorf("failed to read password: %w", err)
			}

			return password, nil
		},
	}))

	return keychain.New(keychain.Args{
		Keyring: ring,
		Label:   serviceName,
	})
}

// initWithCommand initializes the dependencies of the command.
func initWithCommand(cmd *cobra.Command) {
	configureNetworkCompatibility()
	verbose := cmd.Flag("verbose").Value.String() == "true"
	interactive, _ := cmd.Context().Value(interactiveKey).(bool)
	format := util.Must(OutputFormatFromString(cmd.Flag("format").Value.String()))

	dependencies.Logger = newLogger(format, verbose)
	if cmd.Name() == "mcp" {
		dependencies.Logger = log.NewLogger(log.Args{Verbose: verbose, Writer: zerolog.SyncWriter(os.Stderr)})
	}

	dependencies.OS = operatingsystem.New()
	dependencies.Machine = machine.New(machine.Args{OS: dependencies.OS})
	stateDirectory := util.Must(prepareStateDirectory(dependencies.OS, dependencies.Machine.HomeDirectory()))
	dependencies.CookieJar = newCookieJar(stateDirectory)
	dependencies.Keychain = newKeychain(stateDirectory, interactive)
	dependencies.AppStore = appstore.NewAppStore(appstore.Args{
		CookieJar:       dependencies.CookieJar,
		OperatingSystem: dependencies.OS,
		Keychain:        dependencies.Keychain,
		Machine:         dependencies.Machine,
	})
}

// Configure before creating Store or SAP clients, including clients that use
// net/http's default transport. This opt-in applies only to this process.
func configureNetworkCompatibility() {
	if os.Getenv("DUMPSHOP_TLS12") != "1" {
		return
	}
	base, ok := nethttp.DefaultTransport.(*nethttp.Transport)
	if !ok {
		return
	}
	transport := base.Clone()
	if transport.TLSClientConfig == nil {
		transport.TLSClientConfig = &tls.Config{}
	} else {
		transport.TLSClientConfig = transport.TLSClientConfig.Clone()
	}
	transport.TLSClientConfig.MinVersion = tls.VersionTLS12
	transport.TLSClientConfig.MaxVersion = tls.VersionTLS12
	nethttp.DefaultTransport = transport
}
