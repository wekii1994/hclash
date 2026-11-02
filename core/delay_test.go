package core

import (
	"runtime"
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

func TestManualRegistryConcurrentInvariant(t *testing.T) {
	old := runtime.GOMAXPROCS(4)
	defer runtime.GOMAXPROCS(old)
	const (
		key        = "concurrent-node"
		url        = "https://example.com/test"
		iterations = 10000
	)
	for i := 0; i < iterations; i++ {
		doneA := startManualTest(key, url)
		start := make(chan struct{})
		finished := make(chan struct{})
		next := make(chan func(), 1)
		go func() {
			<-start
			doneA()
			close(finished)
		}()
		go func() {
			<-start
			next <- startManualTest(key, url)
		}()
		close(start)
		doneB := <-next
		<-finished
		alive := isManualTest(key, url)
		doneB()
		if !alive {
			t.Fatalf("active test B lost registration at iteration %d", i)
		}
	}
}

func TestManualRegistryReleaseIsIdempotent(t *testing.T) {
	const (
		node = "idempotent-node"
		url  = "https://example.com/test"
	)
	a := startManualTest(node, url)
	b := startManualTest(node, url)
	a()
	a() // Duplicate release must be no-op
	if !isManualTest(node, url) {
		t.Fatal("duplicate release removed active registration b")
	}
	b()
	b()
	if isManualTest(node, url) {
		t.Fatal("leaked registration after both released")
	}
	c := startManualTest(node, url)
	a() // Stale release of a must not affect new c
	if !isManualTest(node, url) {
		t.Fatal("stale release of a removed new registration c")
	}
	c()
}
