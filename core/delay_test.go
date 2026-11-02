package core

import (
	"testing"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/tunnel"
)

func TestManualTestSuppressionLifecycle(t *testing.T) {
	name := "test-node"
	url := "https://example.com/test"

	if isManualTest(name, url) {
		t.Fatalf("expected isManualTest to be false initially")
	}

	done := startManualTest(name, url)
	if !isManualTest(name, url) {
		t.Fatalf("expected isManualTest to be true after start")
	}

	// Another test for same target
	done2 := startManualTest(name, url)
	if !isManualTest(name, url) {
		t.Fatalf("expected isManualTest to stay true with 2 callers")
	}

	done()
	if !isManualTest(name, url) {
		t.Fatalf("expected isManualTest to stay true with 1 remaining caller")
	}

	done2()
	if isManualTest(name, url) {
		t.Fatalf("expected isManualTest to be false after all callers done")
	}
}

func TestUrlTestHookFilters(t *testing.T) {
	direct := outbound.NewDirectWithOption(outbound.DirectOption{Name: "DIRECT"})
	tunnel.UpdateProxies(map[string]constant.Proxy{
		"DIRECT": adapter.NewProxy(direct),
	}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })

	// Unknown proxy should be filtered out
	if lookupProxy("non-existent") != nil {
		t.Fatalf("expected non-existent proxy lookup to be nil")
	}

	// Manual test should be suppressed
	done := startManualTest("DIRECT", "https://example.com/test")
	defer done()
	if !isManualTest("DIRECT", "https://example.com/test") {
		t.Fatalf("expected manual test to be identified")
	}
}

func TestHandleTestDelayEpochChange(t *testing.T) {
	direct := outbound.NewDirectWithOption(outbound.DirectOption{Name: "DIRECT"})
	tunnel.UpdateProxies(map[string]constant.Proxy{
		"DIRECT": adapter.NewProxy(direct),
	}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })

	// Normal run
	res := handleTestDelay(&TestDelayParams{
		ProxyName: "DIRECT",
		TestUrl:   "https://example.com",
		Timeout:   100,
	})
	if res == nil {
		t.Fatalf("expected non-nil result for normal run")
	}

	// Simulating epoch bump during test execution
	startEpoch, _ := routeStamp()
	currentRoute.mu.Lock()
	currentRoute.epoch++
	currentRoute.mu.Unlock()
	t.Cleanup(func() {
		currentRoute.mu.Lock()
		currentRoute.epoch = startEpoch
		currentRoute.mu.Unlock()
	})

	// Missing proxy
	missing := handleTestDelay(&TestDelayParams{
		ProxyName: "unknown-proxy",
		TestUrl:   "https://example.com",
		Timeout:   100,
	})
	if missing == nil || missing.Value != delayFailed {
		t.Fatalf("expected delayFailed for missing proxy, got %v", missing)
	}
}
