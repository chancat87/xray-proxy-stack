package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

const agentToken = "agent-token-0123456789abcdef0123456789abcdef"

// call is one psm invocation seen by the fake runner.
type call struct {
	args  []string
	stdin string
}

type fakeRunner struct {
	mu     sync.Mutex
	calls  []call
	stdout map[string]string // by the psm subcommand ("add", "export", …; "" for `psm version`)
	fail   map[string]string // subcommand → stderr of a failure
}

func (f *fakeRunner) run(_ context.Context, stdin []byte, args ...string) ([]byte, []byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, call{args, string(stdin)})
	sub := ""
	if len(args) > 1 {
		sub = args[1]
	}
	if msg, ok := f.fail[sub]; ok {
		return nil, []byte(msg), errors.New("exit status 1")
	}
	return []byte(f.stdout[sub]), nil, nil
}

// fakePanel serves /api/agent/sync: the queued tasks once, and records every
// request's body.
type fakePanel struct {
	mu       sync.Mutex
	tasks    []task
	requests []map[string]json.RawMessage
	failNext int // answer this many syncs with 500
}

func (p *fakePanel) handler(t *testing.T) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p.mu.Lock()
		defer p.mu.Unlock()
		switch r.URL.Path {
		case "/api/agent/join":
			var body map[string]string
			_ = json.NewDecoder(r.Body).Decode(&body)
			if body["join_token"] != "join-ok" {
				w.WriteHeader(http.StatusForbidden)
				_, _ = io.WriteString(w, `{"error":{"message":"invalid or expired join token"}}`)
				return
			}
			_, _ = io.WriteString(w, `{"agent_token":"`+agentToken+`","server":{"id":1,"name":"hk1"}}`)
		case "/api/agent/sync":
			if r.Header.Get("Authorization") != "Bearer "+agentToken {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			if p.failNext > 0 {
				p.failNext--
				w.WriteHeader(http.StatusInternalServerError)
				return
			}
			var body map[string]json.RawMessage
			_ = json.NewDecoder(r.Body).Decode(&body)
			p.requests = append(p.requests, body)
			resp, _ := json.Marshal(map[string]any{"interval": 10, "tasks": p.tasks})
			p.tasks = nil
			_, _ = w.Write(resp)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
}

// newTestAgent: the traffic report, the relay measurement and the version
// lookup are not due, so the psm calls a test sees are those of its tasks.
func newTestAgent(t *testing.T, p *fakePanel, f *fakeRunner) (*agent, func()) {
	srv := httptest.NewServer(p.handler(t))
	return &agent{cfg: &config{Panel: srv.URL, Token: agentToken, AllowHTTP: true}, run: f.run, hostname: "hk1",
		lastTraffic: time.Now(), lastRelay: time.Now(), versionAt: time.Now(),
		psmVersion: "2026-09-15 abc1234"}, srv.Close
}

func results(t *testing.T, raw json.RawMessage) []result {
	t.Helper()
	var rs []result
	if err := json.Unmarshal(raw, &rs); err != nil {
		t.Fatalf("results: %v (%s)", err, raw)
	}
	return rs
}

// What the panel's relay charts are drawn from: every relayEvery the agent
// measures each relay and the reading travels with the next sync — and then
// not again until it is due, which is what keeps the measurement out of the
// psm calls the other tests assert on.
func TestRelaysAreMeasuredForThePanel(t *testing.T) {
	p := &fakePanel{}
	f := &fakeRunner{stdout: map[string]string{
		"probe": `{"api_version":1,"count":1,"items":[{"tag":"r1","rtt_ms":12.5,"jitter_ms":0.5,"loss_pct":0,"bytes":42}]}`,
	}}
	a, done := newTestAgent(t, p, f)
	defer done()
	a.lastRelay = time.Time{} // due, as it is when psm-agent has just started

	if _, err := a.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	probe := []string{"relay", "probe", "--json"}
	measured := false
	for _, c := range f.calls {
		if reflect.DeepEqual(c.args, probe) {
			measured = true
		}
	}
	if !measured {
		t.Fatalf("the relays were not measured: %q", f.calls)
	}
	if len(p.requests) == 0 || len(p.requests[0]["relays"]) == 0 {
		t.Fatalf("the sync carried no relays: %v", p.requests)
	}
	if a.lastRelay.IsZero() {
		t.Fatal("the next sync would measure all over again")
	}

	f.calls = nil
	if _, err := a.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	for _, c := range f.calls {
		if reflect.DeepEqual(c.args, probe) {
			t.Fatalf("measured again before it was due: %q", f.calls)
		}
	}
}

func TestJoinWritesConfig(t *testing.T) {
	p := &fakePanel{}
	srv := httptest.NewServer(p.handler(t))
	defer srv.Close()
	path := filepath.Join(t.TempDir(), "etc", "agent.json")

	if err := join(context.Background(), path, srv.URL, "join-wrong", true); err == nil || !strings.Contains(err.Error(), "403") {
		t.Fatalf("a wrong join token: err=%v, want a 403", err)
	}
	if _, err := os.Stat(path); err == nil {
		t.Fatal("a failed join wrote a config")
	}
	if err := join(context.Background(), path, srv.URL, "join-ok", true); err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(path)
	if err != nil || st.Mode().Perm() != 0o600 {
		t.Fatalf("config: %v, mode %v, want 0600", err, st.Mode().Perm())
	}
	cfg, err := loadConfig(path)
	if err != nil || cfg.Token != agentToken || cfg.Panel != srv.URL {
		t.Fatalf("config read back: %+v %v", cfg, err)
	}
}

func TestPanelMustBeHTTPS(t *testing.T) {
	for raw, ok := range map[string]bool{
		"https://psm.example.com": true, "https://psm.example.com/": true,
		"http://psm.example.com": false, "psm.example.com": false, "https://psm.example.com/?a=1": false, "ftp://x": false,
	} {
		if _, err := checkPanelURL(raw, false); (err == nil) != ok {
			t.Errorf("%s: err=%v, want ok=%v", raw, err, ok)
		}
	}
}

func TestSniFindSendsTheKeyOnStdinOnly(t *testing.T) {
	p := &fakePanel{tasks: []task{
		{ID: 1, Kind: "sni.find", Data: json.RawMessage(`{"engine":"netlas","key":"k-123"}`)},
		{ID: 2, Kind: "sni.find", Data: json.RawMessage(`{"engine":"--help","key":"k"}`)},
		{ID: 3, Kind: "sni.find", Data: json.RawMessage(`{"engine":"fofa","key":"a\nb"}`)},
		{ID: 4, Kind: "sni.find", Data: json.RawMessage(`{"engine":"quake"}`)},
	}}
	f := &fakeRunner{stdout: map[string]string{"find": `{"candidates":[]}`}}
	a, done := newTestAgent(t, p, f)
	defer done()

	if _, err := a.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	want := []call{{[]string{"sni", "find", "--engine", "netlas", "--key-stdin", "--json"}, "k-123\n"}}
	if !reflect.DeepEqual(f.calls, want) {
		t.Fatalf("psm calls\n got %q\nwant %q (a bad engine, a key with a newline or no key never reaches psm)", f.calls, want)
	}
}

func TestSyncRunsTasksAndReportsResults(t *testing.T) {
	p := &fakePanel{tasks: []task{
		{ID: 1, Kind: "node.add", Core: "xray", Protocol: "reality", Data: json.RawMessage(`{"tag":"hk","port":443,"server_name":"a.example"}`), Server: "203.0.113.10", Format: "uri"},
		{ID: 2, Kind: "node.delete", Core: "sing-box", Protocol: "tuic", Tag: "old"},
	}}
	f := &fakeRunner{stdout: map[string]string{"install": `{"core":"xray","installed":true}`, "add": `{"status":"created"}`,
		"export": "vless://x@203.0.113.10:443#PSM-hk\n", "delete": `{"status":"deleted"}`}}
	a, done := newTestAgent(t, p, f)
	defer done()

	if wait, err := a.step(context.Background()); err != nil || wait != 0 {
		t.Fatalf("first sync: wait=%v err=%v (with results pending it reports at once)", wait, err)
	}
	want := []call{
		{[]string{"core", "install", "xray", "--if-missing", "--json"}, ""},
		{[]string{"node", "add", "xray", "reality", "--input", "-", "--json"}, `{"tag":"hk","port":443,"server_name":"a.example"}`},
		{[]string{"node", "export", "xray", "reality", "hk", "--format", "uri", "--server", "203.0.113.10"}, ""},
		{[]string{"node", "export", "xray", "reality", "hk", "--format", "singbox", "--server", "203.0.113.10"}, ""},
		{[]string{"node", "export", "xray", "reality", "hk", "--format", "clash", "--server", "203.0.113.10"}, ""},
		{[]string{"node", "delete", "sing-box", "tuic", "old", "--yes", "--if-exists", "--json"}, ""},
	}
	if !reflect.DeepEqual(f.calls, want) {
		t.Fatalf("psm calls\n got %q\nwant %q", f.calls, want)
	}
	if wait, err := a.step(context.Background()); err != nil || wait.Seconds() != 10 {
		t.Fatalf("second sync: wait=%v err=%v", wait, err)
	}
	rs := results(t, p.requests[1]["results"])
	if len(rs) != 2 || !rs[0].OK || rs[0].Link != "vless://x@203.0.113.10:443#PSM-hk" || rs[0].Outbound != nil || !rs[1].OK {
		t.Fatalf("results delivered: %+v", rs)
	}
	if len(results(t, p.requests[0]["results"])) != 0 {
		t.Error("the first sync carried results before any task ran")
	}
	if string(p.requests[0]["psm_version"]) != `"2026-09-15 abc1234"` {
		t.Errorf("psm_version sent: %s", p.requests[0]["psm_version"])
	}
}

func TestACoreThatWillNotInstallFailsTheNode(t *testing.T) {
	p := &fakePanel{tasks: []task{{ID: 4, Kind: "node.add", Core: "mihomo", Protocol: "anytls", Data: json.RawMessage(`{"tag":"m","port":8443}`)}}}
	f := &fakeRunner{fail: map[string]string{"install": "psm core: installing mihomo failed\n"}}
	a, done := newTestAgent(t, p, f)
	defer done()
	_, _ = a.step(context.Background())
	_, _ = a.step(context.Background())
	if len(f.calls) != 1 {
		t.Fatalf("psm node add ran although the core did not install: %q", f.calls)
	}
	rs := results(t, p.requests[1]["results"])
	if len(rs) != 1 || rs[0].OK || rs[0].Error != "installing mihomo: psm core: installing mihomo failed" {
		t.Fatalf("result %+v", rs)
	}
}

func TestStandaloneAndTrafficTasks(t *testing.T) {
	p := &fakePanel{tasks: []task{
		{ID: 1, Kind: "standalone.install", Protocol: "snell", Tag: "hk-snell", Data: json.RawMessage(`{"port":31000,"version":"6","psk":"abcdefgh12"}`), Server: "203.0.113.10", Format: "surge"},
		{ID: 2, Kind: "standalone.install", Protocol: "ss2022", Tag: "hk-ss", Data: json.RawMessage(`{"port":31001,"method":"2022-blake3-aes-256-gcm"}`), Server: "203.0.113.10", Format: "uri"},
		{ID: 3, Kind: "traffic.set", Tag: "hk-ss", LimitBytes: 1 << 30, ResetDay: 5},
		{ID: 4, Kind: "traffic.set", Tag: "hk-snell"},
		{ID: 5, Kind: "traffic.reset", Tag: "hk-ss"},
		{ID: 6, Kind: "standalone.remove", Protocol: "snell"},
	}}
	f := &fakeRunner{stdout: map[string]string{"install": `{"active":true}`, "export": `{"type":"shadowsocks"}`,
		"set": `{"tag":"x"}`, "reset": `{"tag":"x"}`, "remove": `{"status":"removed"}`}}
	a, done := newTestAgent(t, p, f)
	defer done()
	if _, err := a.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	want := [][]string{
		{"standalone", "install", "snell", "--port", "31000", "--json", "--version", "6", "--psk", "abcdefgh12"},
		{"standalone", "export", "snell", "--name", "PSM-hk-snell", "--format", "surge", "--server", "203.0.113.10"},
		{"standalone", "export", "snell", "--name", "PSM-hk-snell", "--format", "singbox", "--server", "203.0.113.10"},
		{"standalone", "install", "ss2022", "--port", "31001", "--json", "--method", "2022-blake3-aes-256-gcm"},
		{"standalone", "export", "ss2022", "--name", "PSM-hk-ss", "--format", "uri", "--server", "203.0.113.10"},
		{"standalone", "export", "ss2022", "--name", "PSM-hk-ss", "--format", "singbox", "--server", "203.0.113.10"},
		{"traffic", "set", "hk-ss", "--limit-bytes", "1073741824", "--json", "--reset-day", "5"},
		{"traffic", "set", "hk-snell", "--limit-bytes", "0", "--json"},
		{"traffic", "reset", "hk-ss", "--json"},
		{"standalone", "remove", "snell", "--yes", "--json"},
	}
	var got [][]string
	for _, c := range f.calls {
		got = append(got, c.args)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("psm calls\n got %q\nwant %q", got, want)
	}
	if !a.lastTraffic.IsZero() {
		t.Error("a traffic task did not make the counters due")
	}
	f.stdout["list"] = `[{"tag":"hk-ss","used_bytes":5}]`
	_, _ = a.step(context.Background())
	req := p.requests[len(p.requests)-1]
	if string(req["traffic"]) != `[{"tag":"hk-ss","used_bytes":5}]` {
		t.Fatalf("traffic sent: %s", req["traffic"])
	}
	rs := results(t, req["results"])
	if len(rs) != 6 || string(rs[1].Outbound) != `{"type":"shadowsocks"}` || rs[0].Link == "" {
		t.Fatalf("results: %+v", rs)
	}
	for _, r := range rs {
		if !r.OK {
			t.Errorf("task %d failed: %s", r.TaskID, r.Error)
		}
	}
}

func TestTrafficIsReportedWhenDue(t *testing.T) {
	p := &fakePanel{}
	f := &fakeRunner{stdout: map[string]string{"list": `[{"tag":"a","used_bytes":1}]`}}
	a, done := newTestAgent(t, p, f)
	defer done()
	a.lastTraffic = time.Now().Add(-trafficEvery)
	_, _ = a.step(context.Background())
	_, _ = a.step(context.Background())
	if string(p.requests[0]["traffic"]) != `[{"tag":"a","used_bytes":1}]` {
		t.Fatalf("first sync traffic: %s", p.requests[0]["traffic"])
	}
	if _, sent := p.requests[1]["traffic"]; sent {
		t.Fatal("traffic sent again before ten minutes")
	}
	// the panel can ask for the counters at once
	p.tasks = []task{{ID: 9, Kind: "traffic.report"}}
	_, _ = a.step(context.Background()) // takes the task
	_, _ = a.step(context.Background()) // reports its result, with the counters
	if string(p.requests[3]["traffic"]) != `[{"tag":"a","used_bytes":1}]` {
		t.Fatalf("traffic after traffic.report: %s", p.requests[3]["traffic"])
	}
}

func TestLeaveRemovesTheNodesThenTheAgent(t *testing.T) {
	p := &fakePanel{tasks: []task{{ID: 5, Kind: "agent.leave", Data: json.RawMessage(
		`{"nodes":[{"core":"xray","protocol":"reality","tag":"a"},{"core":"sing-box","protocol":"ss2022","tag":"b"}],"standalone":["snell"],"relays":["r1"]}`)}}}
	f := &fakeRunner{stdout: map[string]string{"delete": `{"status":"deleted"}`, "remove": `{"status":"removed"}`}}
	a, done := newTestAgent(t, p, f)
	defer done()
	var spawned [][]string
	a.spawn = func(args ...string) error { spawned = append(spawned, args); return nil }

	if _, err := a.step(context.Background()); err != nil { // runs the task
		t.Fatal(err)
	}
	want := [][]string{
		{"node", "delete", "xray", "reality", "a", "--yes", "--if-exists", "--json"},
		{"node", "delete", "sing-box", "ss2022", "b", "--yes", "--if-exists", "--json"},
		{"standalone", "remove", "snell", "--yes", "--json"},
		// the relays go too, or realm keeps forwarding on a machine the panel
		// has forgotten, with its accounting rules still in place
		{"relay", "delete", "r1", "--yes", "--if-exists", "--json"},
	}
	var got [][]string
	for _, c := range f.calls {
		got = append(got, c.args)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("psm calls\n got %q\nwant %q", got, want)
	}
	if len(spawned) != 0 || a.left {
		t.Fatal("psm-agent started removing itself before the panel had the result")
	}
	if _, err := a.step(context.Background()); err != nil { // delivers it
		t.Fatal(err)
	}
	rs := results(t, p.requests[1]["results"])
	if len(rs) != 1 || !rs[0].OK || string(rs[0].Output) != `{"failed":[],"removed":["a","b","snell","r1"]}` {
		t.Fatalf("leave result: %+v", rs)
	}
	if !a.left || !reflect.DeepEqual(spawned, [][]string{{"agent", "remove", "--yes"}}) {
		t.Fatalf("after delivering: left=%v spawned=%q", a.left, spawned)
	}
}

// The panel asks for a newer psm-agent. The upgrade replaces this binary and
// restarts the service, so it must not begin before the panel has the result:
// the restart would kill the very process that reports it, leaving the task
// stuck in 下发中 forever.
func TestTheAgentUpgradesItselfOnlyAfterReporting(t *testing.T) {
	p := &fakePanel{tasks: []task{{ID: 7, Kind: "agent.update"}}}
	f := &fakeRunner{}
	a, done := newTestAgent(t, p, f)
	defer done()
	var spawned [][]string
	a.spawn = func(args ...string) error { spawned = append(spawned, args); return nil }

	if _, err := a.step(context.Background()); err != nil { // runs the task
		t.Fatal(err)
	}
	if len(f.calls) != 0 {
		t.Fatalf("the upgrade ran a psm command before reporting: %q", f.calls)
	}
	if len(spawned) != 0 || a.upgraded {
		t.Fatal("psm-agent started upgrading itself before the panel had the result")
	}
	if _, err := a.step(context.Background()); err != nil { // delivers it
		t.Fatal(err)
	}
	rs := results(t, p.requests[1]["results"])
	if len(rs) != 1 || !rs[0].OK || string(rs[0].Output) != `{"from":"`+agentVersion+`"}` {
		t.Fatalf("update result: %+v", rs)
	}
	if !a.upgraded || a.upgrading || !reflect.DeepEqual(spawned, [][]string{{"agent", "upgrade", "--yes"}}) {
		t.Fatalf("after delivering: upgraded=%v upgrading=%v spawned=%q", a.upgraded, a.upgrading, spawned)
	}
	// started once: a later sync must not run the upgrade all over again
	if _, err := a.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(spawned) != 1 {
		t.Fatalf("the upgrade was started again: %q", spawned)
	}
}

func TestABadLeavePlanRemovesNothing(t *testing.T) {
	p := &fakePanel{tasks: []task{
		{ID: 1, Kind: "agent.leave", Data: json.RawMessage(`{"nodes":[{"core":"xray","protocol":"reality","tag":"ok"},{"core":"xray","protocol":"reality","tag":"--all"}]}`)},
		{ID: 2, Kind: "agent.leave", Data: json.RawMessage(`{"standalone":["hysteria2"]}`)},
		{ID: 3, Kind: "agent.leave", Data: json.RawMessage(`[1]`)},
	}}
	f := &fakeRunner{}
	a, done := newTestAgent(t, p, f)
	defer done()
	a.spawn = func(args ...string) error { t.Fatalf("spawned %q for a rejected plan", args); return nil }
	_, _ = a.step(context.Background())
	_, _ = a.step(context.Background())
	if len(f.calls) != 0 || a.leaving || a.left {
		t.Fatalf("calls=%q leaving=%v left=%v", f.calls, a.leaving, a.left)
	}
	for _, r := range results(t, p.requests[1]["results"]) {
		if r.OK || !strings.HasPrefix(r.Error, "rejected by psm-agent") {
			t.Errorf("task %d: %+v", r.TaskID, r)
		}
	}
}

func TestBadTasksNeverReachPSM(t *testing.T) {
	p := &fakePanel{tasks: []task{
		{ID: 1, Kind: "node.add", Core: "v2ray", Protocol: "reality", Data: json.RawMessage(`{"tag":"a","port":1}`)},
		{ID: 2, Kind: "node.add", Core: "xray", Protocol: "naive", Data: json.RawMessage(`{"tag":"a","port":1}`)},
		{ID: 3, Kind: "node.add", Core: "xray", Protocol: "reality", Data: json.RawMessage(`{"tag":"--show-secrets","port":1}`)},
		{ID: 4, Kind: "node.add", Core: "xray", Protocol: "reality", Data: json.RawMessage(`{"tag":"a","port":70000}`)},
		{ID: 5, Kind: "node.add", Core: "xray", Protocol: "reality", Data: json.RawMessage(`[1,2]`)},
		{ID: 6, Kind: "node.delete", Core: "xray", Protocol: "reality", Tag: "--yes"},
		{ID: 7, Kind: "node.update", Core: "xray", Protocol: "reality", Tag: "a", Data: json.RawMessage(`"x"`)},
		{ID: 8, Kind: "node.export", Core: "xray", Protocol: "reality", Tag: "a", Server: "$(id)"},
		{ID: 9, Kind: "shell", Core: "xray", Protocol: "reality"},
		{ID: 10, Kind: "standalone.install", Protocol: "hysteria2", Tag: "a", Data: json.RawMessage(`{"port":1}`)},
		{ID: 11, Kind: "standalone.install", Protocol: "snell", Tag: "a", Data: json.RawMessage(`{"port":1,"psk":"--help me"}`)},
		{ID: 12, Kind: "standalone.install", Protocol: "snell", Tag: "a", Data: json.RawMessage(`{"port":1,"version":"3"}`)},
		{ID: 13, Kind: "standalone.install", Protocol: "ss2022", Tag: "a", Data: json.RawMessage(`{"port":1,"method":"aes-256-gcm"}`)},
		{ID: 14, Kind: "standalone.install", Protocol: "ss2022", Tag: "a", Data: json.RawMessage(`{"port":1,"password":"not base64!"}`)},
		{ID: 15, Kind: "standalone.install", Protocol: "ss2022", Tag: "-a", Data: json.RawMessage(`{"port":1}`)},
		{ID: 16, Kind: "standalone.remove", Protocol: "xray"},
		{ID: 17, Kind: "traffic.set", Tag: "--all", LimitBytes: 1},
		{ID: 18, Kind: "traffic.set", Tag: "a", LimitBytes: -1},
		{ID: 19, Kind: "traffic.set", Tag: "a", ResetDay: 31},
		{ID: 20, Kind: "traffic.reset", Tag: "a b"},
	}}
	f := &fakeRunner{}
	a, done := newTestAgent(t, p, f)
	defer done()
	if _, err := a.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(f.calls) != 0 {
		t.Fatalf("psm ran for a bad task: %q", f.calls)
	}
	if _, err := a.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	rs := results(t, p.requests[1]["results"])
	if len(rs) != 20 {
		t.Fatalf("%d results, want 20", len(rs))
	}
	for _, r := range rs {
		if r.OK || !strings.HasPrefix(r.Error, "rejected by psm-agent") {
			t.Errorf("task %d: %+v, want a rejection", r.TaskID, r)
		}
	}
}

func TestPSMFailureIsReported(t *testing.T) {
	p := &fakePanel{tasks: []task{{ID: 7, Kind: "node.add", Core: "xray", Protocol: "tuic", Data: json.RawMessage(`{"tag":"t","port":9443}`)}}}
	f := &fakeRunner{fail: map[string]string{"add": "loading…\npsm node: unsupported core/protocol: xray/tuic\n"}}
	a, done := newTestAgent(t, p, f)
	defer done()
	_, _ = a.step(context.Background())
	_, _ = a.step(context.Background())
	rs := results(t, p.requests[1]["results"])
	if len(rs) != 1 || rs[0].OK || rs[0].Error != "psm node: unsupported core/protocol: xray/tuic" {
		t.Fatalf("result %+v", rs)
	}
}

func TestStatusGathersTheServer(t *testing.T) {
	p := &fakePanel{tasks: []task{{ID: 3, Kind: "status"}}}
	f := &fakeRunner{stdout: map[string]string{"list": `{"count":0,"items":[]}`, "show": `{"installed":false}`},
		fail: map[string]string{"--json": "doctor found problems\n"}}
	a, done := newTestAgent(t, p, f)
	defer done()
	_, _ = a.step(context.Background())
	_, _ = a.step(context.Background())
	rs := results(t, p.requests[1]["results"])
	var st map[string]json.RawMessage
	if len(rs) != 1 || !rs[0].OK || json.Unmarshal(rs[0].Output, &st) != nil {
		t.Fatalf("status result %+v", rs)
	}
	if string(st["nodes"]) != `{"count":0,"items":[]}` || string(st["snell"]) != `{"installed":false}` || string(st["agent_version"]) != `"`+agentVersion+`"` {
		t.Fatalf("status: %s", rs[0].Output)
	}
}

func TestResultsSurviveAFailedSync(t *testing.T) {
	p := &fakePanel{tasks: []task{{ID: 3, Kind: "status"}}}
	f := &fakeRunner{stdout: map[string]string{"list": `{"count":0,"items":[]}`}}
	a, done := newTestAgent(t, p, f)
	defer done()
	if _, err := a.step(context.Background()); err != nil { // runs the task
		t.Fatal(err)
	}
	p.failNext = 1
	if _, err := a.step(context.Background()); err == nil {
		t.Fatal("a 500 from the panel was not an error")
	}
	if len(a.pending) != 1 {
		t.Fatalf("%d pending results after a failed sync, want 1", len(a.pending))
	}
	if _, err := a.step(context.Background()); err != nil {
		t.Fatal(err)
	}
	if rs := results(t, p.requests[len(p.requests)-1]["results"]); len(rs) != 1 || rs[0].TaskID != 3 || !rs[0].OK {
		t.Fatalf("delivered after the retry: %+v", rs)
	}
}

func TestWrongTokenIsAnHTTPError(t *testing.T) {
	p := &fakePanel{}
	a, done := newTestAgent(t, p, &fakeRunner{})
	defer done()
	a.cfg.Token = "wrong-token-0123456789abcdef0123456789abcdef"
	_, err := a.step(context.Background())
	var he *httpError
	if !errors.As(err, &he) || he.status != http.StatusUnauthorized {
		t.Fatalf("err=%v, want a 401 httpError", err)
	}
}
