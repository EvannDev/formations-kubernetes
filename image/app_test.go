package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// --- configuration -------------------------------------------------------------

func env(values map[string]string) func(string) string {
	return func(name string) string { return values[name] }
}

func TestLoadConfigDefaults(t *testing.T) {
	cfg, err := loadConfig(env(nil))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.appName != "formations-kubernetes" || cfg.displayedVersion != version {
		t.Errorf("unexpected defaults: %+v", cfg)
	}
	if cfg.startupDelay != 0 || cfg.memoryBalloonMB != 0 || len(cfg.requiredVars) != 0 {
		t.Errorf("behaviors enabled by default: %+v", cfg)
	}
}

func TestLoadConfigFull(t *testing.T) {
	cfg, err := loadConfig(env(map[string]string{
		"NOM_APPLI":              "api-paiements",
		"VERSION_AFFICHEE":       "9.9",
		"EXIGE_VARS":             "DEVISE, BD_MOT_DE_PASSE,",
		"DELAI_DEMARRAGE":        "45",
		"READINESS_ECHOUE_APRES": "60",
		"BALLON_MEMOIRE_MO":      "150",
	}))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.appName != "api-paiements" || cfg.displayedVersion != "9.9" {
		t.Errorf("name or version: %+v", cfg)
	}
	if strings.Join(cfg.requiredVars, ",") != "DEVISE,BD_MOT_DE_PASSE" {
		t.Errorf("EXIGE_VARS badly split: %q", cfg.requiredVars)
	}
	if cfg.startupDelay != 45*time.Second || cfg.readinessFailAfter != 60*time.Second || cfg.memoryBalloonMB != 150 {
		t.Errorf("durations or balloon: %+v", cfg)
	}
}

func TestLoadConfigInvalid(t *testing.T) {
	for _, value := range []string{"abc", "-5", "1.5"} {
		_, err := loadConfig(env(map[string]string{"DELAI_DEMARRAGE": value}))
		if err == nil || !strings.Contains(err.Error(), "DELAI_DEMARRAGE") {
			t.Errorf("DELAI_DEMARRAGE=%q: expected an error, got %v", value, err)
		}
	}
}

func TestMissingVars(t *testing.T) {
	present := map[string]string{"DEVISE": "CAD", "DB_MOT_DE_PASSE": "x"}
	lookup := func(name string) (string, bool) { v, ok := present[name]; return v, ok }

	missing := missingVars([]string{"DEVISE", "BD_MOT_DE_PASSE"}, lookup)
	if len(missing) != 1 || missing[0] != "BD_MOT_DE_PASSE" {
		t.Fatalf("missing = %q", missing)
	}
}

func TestMissingVarsMessage(t *testing.T) {
	required := []string{"DEVISE", "BD_MOT_DE_PASSE"}
	// Quoted verbatim in the workshop 1 trainer guide
	want := "ERREUR : variable obligatoire absente : BD_MOT_DE_PASSE (EXIGE_VARS=DEVISE,BD_MOT_DE_PASSE)"
	if got := missingVarsMessage([]string{"BD_MOT_DE_PASSE"}, required); got != want {
		t.Errorf("message:\n got  %s\n want %s", got, want)
	}
	if got := missingVarsMessage(required, required); !strings.Contains(got, "variables obligatoires absentes : DEVISE, BD_MOT_DE_PASSE") {
		t.Errorf("plural message: %s", got)
	}
}

// --- routes ------------------------------------------------------------------

// testApp creates an app whose clock is frozen at "elapsed" after startup.
func testApp(cfg config, elapsed time.Duration) *app {
	a := newApp(cfg, "pod-test", "bdc")
	a.now = func() time.Time { return a.start.Add(elapsed) }
	return a
}

func get(t *testing.T, a *app, path string) (int, map[string]any) {
	t.Helper()
	w := httptest.NewRecorder()
	a.ServeHTTP(w, httptest.NewRequest(http.MethodGet, path, nil))
	var body map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &body); err != nil {
		t.Fatalf("%s: non-JSON response: %q", path, w.Body.String())
	}
	return w.Code, body
}

func TestRoot(t *testing.T) {
	a := testApp(config{appName: "api-paiements", displayedVersion: "1.0"}, 0)
	w := httptest.NewRecorder()
	a.ServeHTTP(w, httptest.NewRequest(http.MethodGet, "/", nil))

	// Exact format expected by the workshop instructions and verifier.sh
	want := `{"appli":"api-paiements","version":"1.0","pod":"pod-test","namespace":"bdc"}` + "\n"
	if w.Code != http.StatusOK || w.Body.String() != want {
		t.Errorf("got %d %q, want 200 %q", w.Code, w.Body.String(), want)
	}
}

func TestNotFound(t *testing.T) {
	a := testApp(config{appName: "api-paiements"}, 0)
	// /ready (instead of /readyz) must return 404: workshop 3, defect 2
	for _, path := range []string{"/ready", "/bdc-edb", "/healthz/"} {
		code, body := get(t, a, path)
		if code != http.StatusNotFound || body["erreur"] != "route inconnue" || body["chemin"] != path {
			t.Errorf("%s: %d %v", path, code, body)
		}
	}
}

func TestProbes(t *testing.T) {
	cfg := config{
		startupDelay:       45 * time.Second,
		readinessFailAfter: 60 * time.Second,
		livenessFailAfter:  90 * time.Second,
	}
	cases := []struct {
		elapsed             time.Duration
		liveness, readiness int
	}{
		{10 * time.Second, 503, 503},  // slow startup
		{50 * time.Second, 200, 200},  // started
		{70 * time.Second, 200, 503},  // readiness failing: removed from the Service
		{100 * time.Second, 503, 503}, // liveness failing: restarted
	}
	for _, c := range cases {
		a := testApp(cfg, c.elapsed)
		if code, _ := get(t, a, "/healthz"); code != c.liveness {
			t.Errorf("at %s: /healthz = %d, want %d", c.elapsed, code, c.liveness)
		}
		if code, _ := get(t, a, "/readyz"); code != c.readiness {
			t.Errorf("at %s: /readyz = %d, want %d", c.elapsed, code, c.readiness)
		}
	}
}

func TestInfoMasksSecrets(t *testing.T) {
	a := testApp(config{}, 0)
	a.environ = func() []string {
		return []string{"DEVISE=CAD", "BD_MOT_DE_PASSE=formation-bdc", "API_TOKEN=abc"}
	}
	_, body := get(t, a, "/info")
	variables := body["variables"].(map[string]any)
	if variables["DEVISE"] != "CAD" {
		t.Errorf("DEVISE should be visible: %v", variables)
	}
	for _, name := range []string{"BD_MOT_DE_PASSE", "API_TOKEN"} {
		if variables[name] != "*** masqué ***" {
			t.Errorf("%s should be masked: %v", name, variables[name])
		}
	}
}

func TestAllocateMemory(t *testing.T) {
	a := testApp(config{}, 0)
	if code, body := get(t, a, "/memoire?mo=2"); code != 200 || body["memoire_retenue_mo"] != float64(2) {
		t.Errorf("/memoire?mo=2: %d %v", code, body)
	}
	for _, path := range []string{"/memoire", "/memoire?mo=0", "/memoire?mo=abc"} {
		if code, _ := get(t, a, path); code != http.StatusBadRequest {
			t.Errorf("%s: %d, want 400", path, code)
		}
	}
}

func TestBurnCPUInvalidParams(t *testing.T) {
	a := testApp(config{}, 0)
	for _, path := range []string{"/brule?secondes=0", "/brule?secondes=999", "/brule?fils=x"} {
		if code, _ := get(t, a, path); code != http.StatusBadRequest {
			t.Errorf("%s: %d, want 400", path, code)
		}
	}
}

// --- /appel ------------------------------------------------------------------

func TestCallUpstreamSuccess(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, identity{"api-paiements", "1.0", "pod-amont", "bdc"})
	}))
	defer upstream.Close()

	a := testApp(config{upstreamURL: upstream.URL}, 0)
	code, body := get(t, a, "/appel")
	payload, _ := body["reponse"].(map[string]any)
	if code != 200 || body["statut_amont"] != float64(200) || payload["appli"] != "api-paiements" {
		t.Errorf("/appel: %d %v", code, body)
	}
}

func TestCallUpstreamErrors(t *testing.T) {
	// Stopped server: its port refuses connections (workshop 2, defect 1)
	closed := httptest.NewServer(http.NotFoundHandler())
	closedURL := closed.URL
	closed.Close()

	cases := []struct{ url, wantType string }{
		{closedURL, "refus"},
		// .invalid never resolves (RFC 2606): workshop 2, defect 2
		{"http://api-paiements.inexistant.invalid", "dns"},
	}
	for _, c := range cases {
		a := testApp(config{upstreamURL: c.url}, 0)
		code, body := get(t, a, "/appel")
		if code != http.StatusBadGateway || body["type"] != c.wantType {
			t.Errorf("%s: %d %v, want 502 type=%s", c.url, code, body, c.wantType)
		}
	}
}

func TestCallUpstreamWithoutURL(t *testing.T) {
	a := testApp(config{}, 0)
	if code, body := get(t, a, "/appel"); code != http.StatusInternalServerError {
		t.Errorf("/appel without URL_AMONT: %d %v", code, body)
	}
}
