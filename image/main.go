// Training application for the BDC Kubernetes course.
//
// A single image serves every workshop: its behavior (slow startup, failing
// probes, CPU or memory pressure, upstream calls…) is driven by environment
// variables. See README.md (French) for the full interface.
//
// Code is in English; everything participants read (routes, JSON keys, log
// and error messages, variable names) is in French.
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"
)

// version is set at build time: -ldflags "-X main.version=1.0"
var version = "dev"

const port = "8080"

func main() {
	cfg, err := loadConfig(os.Getenv)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if missing := missingVars(cfg.requiredVars, os.LookupEnv); len(missing) > 0 {
		fmt.Fprintln(os.Stderr, missingVarsMessage(missing, cfg.requiredVars))
		os.Exit(1)
	}

	pod, _ := os.Hostname()
	a := newApp(cfg, pod, readNamespace())

	if cfg.memoryBalloonMB > 0 {
		a.allocate(cfg.memoryBalloonMB)
		log.Printf("ballon mémoire : %d Mo alloués et conservés (BALLON_MEMOIRE_MO)", cfg.memoryBalloonMB)
	}
	if cfg.crashAfter > 0 {
		log.Printf("arrêt volontaire prévu dans %s (CRASH_AU_DEMARRAGE)", cfg.crashAfter)
		time.AfterFunc(cfg.crashAfter, func() {
			fmt.Fprintf(os.Stderr, "ERREUR : arrêt volontaire après %d s (CRASH_AU_DEMARRAGE)\n", int(cfg.crashAfter.Seconds()))
			os.Exit(1)
		})
	}
	if cfg.startupDelay > 0 {
		log.Printf("démarrage lent simulé : sondes en 503 pendant %s (DELAI_DEMARRAGE)", cfg.startupDelay)
	}

	server := &http.Server{
		Addr:              ":" + port,
		Handler:           logRequests(a),
		ReadHeaderTimeout: 10 * time.Second,
	}
	go func() {
		log.Printf("%s %s à l'écoute sur :%s (pod %s, namespace %s)", cfg.appName, cfg.displayedVersion, port, pod, a.namespace)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("ERREUR : %v", err)
		}
	}()

	// Graceful shutdown on SIGTERM (sent by Kubernetes before deleting the pod)
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, os.Interrupt)
	sig := <-stop
	log.Printf("signal %s reçu : arrêt propre", sig)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := server.Shutdown(ctx); err != nil {
		log.Printf("arrêt forcé : %v", err)
	}
}

// readNamespace returns the pod namespace, read from the mounted service account.
func readNamespace() string {
	if ns := os.Getenv("POD_NAMESPACE"); ns != "" {
		return ns
	}
	content, err := os.ReadFile("/var/run/secrets/kubernetes.io/serviceaccount/namespace")
	if err != nil {
		return "inconnu"
	}
	return strings.TrimSpace(string(content))
}

// logRequests writes one line per request, except probes (one every few
// seconds: they would drown the logs).
func logRequests(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/healthz" || r.URL.Path == "/readyz" {
			next.ServeHTTP(w, r)
			return
		}
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		log.Printf("%s %s %d %s", r.Method, r.URL.RequestURI(), rec.status, time.Since(start).Round(time.Millisecond))
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(status int) {
	s.status = status
	s.ResponseWriter.WriteHeader(status)
}
