package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// app holds the application state and serves every route.
// Routes, JSON keys and messages are French: participants read them.
type app struct {
	cfg       config
	start     time.Time
	now       func() time.Time // injected for tests
	environ   func() []string  // injected for tests
	pod       string
	namespace string
	client    *http.Client

	mu       sync.Mutex
	retained [][]byte // memory from BALLON_MEMOIRE_MO and /memoire, never released
}

func newApp(cfg config, pod, namespace string) *app {
	return &app{
		cfg:       cfg,
		start:     time.Now(),
		now:       time.Now,
		environ:   os.Environ,
		pod:       pod,
		namespace: namespace,
		client:    &http.Client{Timeout: 5 * time.Second},
	}
}

func (a *app) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch r.URL.Path {
	case "/":
		a.root(w)
	case "/healthz":
		a.probe(w, a.cfg.livenessFailAfter, "LIVENESS_ECHOUE_APRES")
	case "/readyz":
		a.probe(w, a.cfg.readinessFailAfter, "READINESS_ECHOUE_APRES")
	case "/info":
		a.info(w)
	case "/brule":
		a.burnCPU(w, r)
	case "/memoire":
		a.allocateMemory(w, r)
	case "/appel":
		a.callUpstream(w)
	default:
		a.notFound(w, r)
	}
}

// --- / -----------------------------------------------------------------------

type identity struct {
	App       string `json:"appli"`
	Version   string `json:"version"`
	Pod       string `json:"pod"`
	Namespace string `json:"namespace"`
}

func (a *app) identity() identity {
	return identity{a.cfg.appName, a.cfg.displayedVersion, a.pod, a.namespace}
}

func (a *app) root(w http.ResponseWriter) {
	writeJSON(w, http.StatusOK, a.identity())
}

// --- /healthz and /readyz ------------------------------------------------------

// probe answers 503 during DELAI_DEMARRAGE, then 503 from failAfter onwards
// (when set), 200 otherwise. Durations start when the process starts.
func (a *app) probe(w http.ResponseWriter, failAfter time.Duration, variable string) {
	elapsed := a.now().Sub(a.start)
	switch {
	case elapsed < a.cfg.startupDelay:
		remaining := (a.cfg.startupDelay - elapsed).Round(time.Second)
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{
			"statut":  "démarrage en cours",
			"restant": remaining.String(),
		})
	case failAfter > 0 && elapsed >= failAfter:
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{
			"statut": "en échec",
			"cause":  fmt.Sprintf("%s=%d", variable, int(failAfter.Seconds())),
		})
	default:
		writeJSON(w, http.StatusOK, map[string]string{"statut": "ok"})
	}
}

// --- /info -------------------------------------------------------------------

// Variables whose value is masked in /info
var sensitiveName = regexp.MustCompile(`(?i)MOT_DE_PASSE|PASSWORD|PASSWD|SECRET|TOKEN|CLE|KEY|CREDENTIAL`)

func (a *app) info(w http.ResponseWriter) {
	variables := map[string]string{}
	for _, kv := range a.environ() {
		name, value, _ := strings.Cut(kv, "=")
		if sensitiveName.MatchString(name) {
			value = "*** masqué ***"
		}
		variables[name] = value
	}
	writeJSON(w, http.StatusOK, struct {
		identity
		UptimeSeconds int               `json:"depuis_secondes"`
		RetainedMB    int               `json:"memoire_retenue_mo"`
		Cgroup        map[string]string `json:"cgroup"`
		Variables     map[string]string `json:"variables"`
	}{
		identity:      a.identity(),
		UptimeSeconds: int(a.now().Sub(a.start).Seconds()),
		RetainedMB:    a.retainedMB(),
		Cgroup:        cgroupLimits(),
		Variables:     variables,
	})
}

// cgroupLimits reads the container CPU and memory limits (cgroup v2,
// falling back to v1). "max" or "-1" means no limit.
func cgroupLimits() map[string]string {
	read := func(path string) string {
		content, err := os.ReadFile(path)
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(content))
	}

	if memory := read("/sys/fs/cgroup/memory.max"); memory != "" {
		return map[string]string{
			"version":     "v2",
			"memoire_max": toMB(memory),
			"cpu_max":     read("/sys/fs/cgroup/cpu.max"), // "quota period" in µs
		}
	}
	if memory := read("/sys/fs/cgroup/memory/memory.limit_in_bytes"); memory != "" {
		return map[string]string{
			"version":     "v1",
			"memoire_max": toMB(memory),
			"cpu_max":     read("/sys/fs/cgroup/cpu/cpu.cfs_quota_us") + " " + read("/sys/fs/cgroup/cpu/cpu.cfs_period_us"),
		}
	}
	return map[string]string{"version": "inconnue"}
}

func toMB(bytes string) string {
	n, err := strconv.ParseInt(bytes, 10, 64)
	if err != nil || n <= 0 || n >= 1<<62 {
		return bytes
	}
	return fmt.Sprintf("%d Mo", n>>20)
}

// --- /brule ------------------------------------------------------------------

func (a *app) burnCPU(w http.ResponseWriter, r *http.Request) {
	seconds, err := intParam(r, "secondes", 10, 1, 300)
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	threads, err := intParam(r, "fils", 1, 1, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}

	start := time.Now()
	deadline := start.Add(time.Duration(seconds) * time.Second)
	var wg sync.WaitGroup
	for range threads {
		wg.Go(func() {
			for time.Now().Before(deadline) {
				// busy loop: keeps one core busy until the deadline
			}
		})
	}
	wg.Wait()

	writeJSON(w, http.StatusOK, map[string]int{
		"secondes": seconds,
		"fils":     threads,
		"duree_ms": int(time.Since(start).Milliseconds()),
	})
}

// --- /memoire ----------------------------------------------------------------

func (a *app) allocateMemory(w http.ResponseWriter, r *http.Request) {
	mb, err := intParam(r, "mo", -1, 1, 4096)
	if err != nil {
		writeError(w, http.StatusBadRequest, err)
		return
	}
	a.allocate(mb)
	writeJSON(w, http.StatusOK, map[string]int{
		"ajoute_mo":          mb,
		"memoire_retenue_mo": a.retainedMB(),
	})
}

// allocate reserves mb MiB and writes to every page so the memory really
// counts against the container limit.
func (a *app) allocate(mb int) {
	block := make([]byte, mb<<20)
	for i := 0; i < len(block); i += 4096 {
		block[i] = 1
	}
	a.mu.Lock()
	a.retained = append(a.retained, block)
	a.mu.Unlock()
}

func (a *app) retainedMB() int {
	a.mu.Lock()
	defer a.mu.Unlock()
	total := 0
	for _, block := range a.retained {
		total += len(block) >> 20
	}
	return total
}

// --- /appel ------------------------------------------------------------------

func (a *app) callUpstream(w http.ResponseWriter) {
	if a.cfg.upstreamURL == "" {
		writeError(w, http.StatusInternalServerError, errors.New("URL_AMONT n'est pas définie"))
		return
	}

	start := time.Now()
	resp, err := a.client.Get(a.cfg.upstreamURL)
	durationMs := int(time.Since(start).Milliseconds())
	if err != nil {
		writeJSON(w, http.StatusBadGateway, struct {
			URL        string `json:"url"`
			Type       string `json:"type"`
			Error      string `json:"erreur"`
			DurationMs int    `json:"duree_ms"`
		}{a.cfg.upstreamURL, errorType(err), err.Error(), durationMs})
		return
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	var payload any = string(body)
	if json.Valid(body) {
		payload = json.RawMessage(body)
	}
	writeJSON(w, http.StatusOK, struct {
		URL            string `json:"url"`
		UpstreamStatus int    `json:"statut_amont"`
		DurationMs     int    `json:"duree_ms"`
		Response       any    `json:"reponse"`
	}{a.cfg.upstreamURL, resp.StatusCode, durationMs, payload})
}

// errorType classifies a call error: dns, refus (refused), timeout or autre (other).
func errorType(err error) string {
	var dnsErr *net.DNSError
	var netErr net.Error
	switch {
	case errors.As(err, &dnsErr):
		return "dns"
	case errors.Is(err, syscall.ECONNREFUSED):
		return "refus"
	case errors.As(err, &netErr) && netErr.Timeout():
		return "timeout"
	default:
		return "autre"
	}
}

// --- unknown route -------------------------------------------------------------

func (a *app) notFound(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusNotFound, struct {
		Error string `json:"erreur"`
		App   string `json:"appli"`
		Pod   string `json:"pod"`
		Path  string `json:"chemin"`
	}{"route inconnue", a.cfg.appName, a.pod, r.URL.Path})
}

// --- helpers -----------------------------------------------------------------

// intParam reads a bounded integer query parameter.
// A negative fallback makes the parameter mandatory.
func intParam(r *http.Request, name string, fallback, min, max int) (int, error) {
	value := r.URL.Query().Get(name)
	if value == "" {
		if fallback < 0 {
			return 0, fmt.Errorf("paramètre « %s » obligatoire (entre %d et %d)", name, min, max)
		}
		return fallback, nil
	}
	n, err := strconv.Atoi(value)
	if err != nil || n < min || n > max {
		return 0, fmt.Errorf("paramètre « %s » invalide : %q (attendu : entier entre %d et %d)", name, value, min, max)
	}
	return n, nil
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(v)
}

func writeError(w http.ResponseWriter, status int, err error) {
	writeJSON(w, status, map[string]string{"erreur": err.Error()})
}
