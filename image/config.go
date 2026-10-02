package main

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// config holds the settings read from environment variables. Variable names
// are French on purpose: they are part of the training material.
type config struct {
	appName            string
	displayedVersion   string
	requiredVars       []string
	crashAfter         time.Duration
	startupDelay       time.Duration
	readinessFailAfter time.Duration
	livenessFailAfter  time.Duration
	memoryBalloonMB    int
	upstreamURL        string
}

// loadConfig reads and validates the environment.
// getenv is injected for tests (os.Getenv in production).
func loadConfig(getenv func(string) string) (config, error) {
	cfg := config{
		appName:          valueOrDefault(getenv("NOM_APPLI"), "formations-kubernetes"),
		displayedVersion: valueOrDefault(getenv("VERSION_AFFICHEE"), version),
		upstreamURL:      getenv("URL_AMONT"),
	}

	for _, name := range strings.Split(getenv("EXIGE_VARS"), ",") {
		if name = strings.TrimSpace(name); name != "" {
			cfg.requiredVars = append(cfg.requiredVars, name)
		}
	}

	// Durations in seconds; unset or 0 disables the behavior
	durations := []struct {
		name   string
		target *time.Duration
	}{
		{"CRASH_AU_DEMARRAGE", &cfg.crashAfter},
		{"DELAI_DEMARRAGE", &cfg.startupDelay},
		{"READINESS_ECHOUE_APRES", &cfg.readinessFailAfter},
		{"LIVENESS_ECHOUE_APRES", &cfg.livenessFailAfter},
	}
	for _, d := range durations {
		n, err := nonNegativeInt(d.name, getenv(d.name))
		if err != nil {
			return config{}, err
		}
		*d.target = time.Duration(n) * time.Second
	}

	n, err := nonNegativeInt("BALLON_MEMOIRE_MO", getenv("BALLON_MEMOIRE_MO"))
	if err != nil {
		return config{}, err
	}
	cfg.memoryBalloonMB = n

	return cfg, nil
}

// missingVars returns the required variables that are not set.
// lookup is injected for tests (os.LookupEnv in production).
func missingVars(names []string, lookup func(string) (string, bool)) []string {
	var missing []string
	for _, name := range names {
		if _, ok := lookup(name); !ok {
			missing = append(missing, name)
		}
	}
	return missing
}

// missingVarsMessage builds the exit message participants read with
// "kubectl logs --previous". Quoted verbatim in the workshop 1 trainer guide.
func missingVarsMessage(missing, required []string) string {
	list := strings.Join(required, ",")
	if len(missing) == 1 {
		return fmt.Sprintf("ERREUR : variable obligatoire absente : %s (EXIGE_VARS=%s)", missing[0], list)
	}
	return fmt.Sprintf("ERREUR : variables obligatoires absentes : %s (EXIGE_VARS=%s)", strings.Join(missing, ", "), list)
}

func nonNegativeInt(name, value string) (int, error) {
	if value == "" {
		return 0, nil
	}
	n, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil || n < 0 {
		return 0, fmt.Errorf("ERREUR : %s doit être un entier positif (reçu : %q)", name, value)
	}
	return n, nil
}

func valueOrDefault(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}
