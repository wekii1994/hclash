package core

import (
	"context"
	"errors"
	"fmt"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/common/utils"
	"io"
	"net"
	"testing"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/constant"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func TestProxyOnlyTrafficLeavesOutADirectProxyOfAnyName(t *testing.T) {
	direct := outbound.NewDirectWithOption(outbound.DirectOption{Name: "直连"})
	reject := outbound.NewRejectWithOption(outbound.RejectOption{Name: "HK"})
	tunnel.UpdateProxies(map[string]constant.Proxy{
		"直连": adapter.NewProxy(direct),
		"HK": adapter.NewProxy(reject),
	}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })

	for _, test := range []struct {
		outbound constant.ProxyAdapter
		proxied  int64
	}{
		{direct, 0},
		{reject, 5},
	} {
		statistic.DefaultManager.ResetStatistic()
		local, remote := net.Pipe()
		go func() { _, _ = io.Copy(io.Discard, remote) }()
		tracker := statistic.NewTCPTracker(
			outbound.NewConn(local, test.outbound),
			statistic.DefaultManager,
			&constant.Metadata{},
			nil,
			0,
			0,
			true,
		)

		if _, err := tracker.Write([]byte("hello")); err != nil {
			t.Fatalf("write through %s: %v", test.outbound.Name(), err)
		}
		_ = tracker.Close()
		_ = remote.Close()

		all, _ := statistic.DefaultManager.TotalTraffic(false)
		proxied, _ := statistic.DefaultManager.TotalTraffic(true)
		if all != 5 || proxied != test.proxied {
			t.Errorf("%s: total %d, proxied %d; want 5 and %d", test.outbound.Name(), all, proxied, test.proxied)
		}
	}
	statistic.DefaultManager.ResetStatistic()
}

func countConnections() int {
	var count int
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		count++
		return true
	})
	return count
}

func TestOnGroupNowChangedInvokesFailover(t *testing.T) {
	if outboundgroup.OnGroupNowChanged == nil {
		t.Fatal("outboundgroup.OnGroupNowChanged is nil, want initialized in core/connection.go")
	}

	statistic.DefaultManager.ResetStatistic()

	// Mock groups and proxies
	autoGroup := outbound.NewRejectWithOption(outbound.RejectOption{Name: "AutoGroup"})
	otherGroup := outbound.NewRejectWithOption(outbound.RejectOption{Name: "OtherGroup"})
	nodeA := outbound.NewRejectWithOption(outbound.RejectOption{Name: "NodeA"})
	nodeB := outbound.NewRejectWithOption(outbound.RejectOption{Name: "NodeB"})
	direct := outbound.NewDirectWithOption(outbound.DirectOption{Name: "DIRECT"})

	// 1. Connection using AutoGroup -> NodeA (old stale connection) - SHOULD BE CLOSED
	l1, r1 := net.Pipe()
	conn1 := outbound.NewConn(l1, nodeA)
	conn1.AppendToChains(nodeA)
	conn1.AppendToChains(autoGroup)
	tracker1 := statistic.NewTCPTracker(conn1, statistic.DefaultManager, &constant.Metadata{}, nil, 0, 0, true)

	// 2. Connection using OtherGroup -> NodeA (sharing NodeA in another group) - MUST BE PRESERVED
	l2, r2 := net.Pipe()
	conn2 := outbound.NewConn(l2, nodeA)
	conn2.AppendToChains(nodeA)
	conn2.AppendToChains(otherGroup)
	tracker2 := statistic.NewTCPTracker(conn2, statistic.DefaultManager, &constant.Metadata{}, nil, 0, 0, true)

	// 3. Connection using AutoGroup -> NodeB (new node after switch) - MUST BE PRESERVED
	l3, r3 := net.Pipe()
	conn3 := outbound.NewConn(l3, nodeB)
	conn3.AppendToChains(nodeB)
	conn3.AppendToChains(autoGroup)
	tracker3 := statistic.NewTCPTracker(conn3, statistic.DefaultManager, &constant.Metadata{}, nil, 0, 0, true)

	// 4. Connection using DIRECT - MUST BE PRESERVED
	l4, r4 := net.Pipe()
	conn4 := outbound.NewConn(l4, direct)
	conn4.AppendToChains(direct)
	tracker4 := statistic.NewTCPTracker(conn4, statistic.DefaultManager, &constant.Metadata{}, nil, 0, 0, true)

	// Register active proxies so AutoGroup is recognized as the active group instance
	tunnel.UpdateProxies(map[string]constant.Proxy{
		"AutoGroup": adapter.NewProxy(autoGroup),
	}, nil)

	t.Cleanup(func() {
		_ = tracker1.Close()
		_ = tracker2.Close()
		_ = tracker3.Close()
		_ = tracker4.Close()
		_ = r1.Close()
		_ = r2.Close()
		_ = r3.Close()
		_ = r4.Close()
		tunnel.UpdateProxies(nil, nil)
		statistic.DefaultManager.ResetStatistic()
	})

	if count := countConnections(); count != 4 {
		t.Fatalf("expected 4 active connections before failover, got %d", count)
	}

	_, startVersion := routeStamp()

	// Trigger failover for AutoGroup from NodeA to NodeB with active autoGroup instance
	outboundgroup.OnGroupNowChanged(autoGroup, "AutoGroup", "NodeA", "NodeB")

	// Verify: ONLY tracker1 (AutoGroup -> NodeA) is closed!
	// tracker2 (OtherGroup -> NodeA), tracker3 (AutoGroup -> NodeB), tracker4 (DIRECT) must all remain active!
	if count := countConnections(); count != 3 {
		t.Errorf("connection count = %d, want 3 preserved (OtherGroup sharing NodeA, AutoGroup on NodeB, and DIRECT)", count)
	}

	if tracker1.ID() != "" && statistic.DefaultManager.Get(tracker1.ID()) != nil {
		t.Errorf("expected AutoGroup -> NodeA connection to be closed, but still in manager")
	}

	if statistic.DefaultManager.Get(tracker2.ID()) == nil {
		t.Errorf("expected OtherGroup -> NodeA connection to be preserved, but was closed")
	}

	if statistic.DefaultManager.Get(tracker3.ID()) == nil {
		t.Errorf("expected AutoGroup -> NodeB connection to be preserved, but was closed")
	}

	if statistic.DefaultManager.Get(tracker4.ID()) == nil {
		t.Errorf("expected DIRECT connection to be preserved, but was closed")
	}

	_, endVersion := routeStamp()
	if endVersion <= startVersion {
		t.Errorf("route version not incremented: start=%d, end=%d", startVersion, endVersion)
	}
}

func TestStaleGroupInstanceCallbackSuppressedOnConfigReload(t *testing.T) {
	statistic.DefaultManager.ResetStatistic()

	oldGroup := outbound.NewRejectWithOption(outbound.RejectOption{Name: "AutoGroup"})
	newGroup := outbound.NewRejectWithOption(outbound.RejectOption{Name: "AutoGroup"})
	nodeA := outbound.NewRejectWithOption(outbound.RejectOption{Name: "NodeA"})
	nodeB := outbound.NewRejectWithOption(outbound.RejectOption{Name: "NodeB"})

	// Active configuration contains newGroup
	tunnel.UpdateProxies(map[string]constant.Proxy{
		"AutoGroup": adapter.NewProxy(newGroup),
		"NodeA":     adapter.NewProxy(nodeA),
		"NodeB":     adapter.NewProxy(nodeB),
	}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil); statistic.DefaultManager.ResetStatistic() })

	// A new connection is established through the new configuration (newGroup -> NodeA)
	l, r := net.Pipe()
	conn := outbound.NewConn(l, nodeA)
	conn.AppendToChains(nodeA)
	conn.AppendToChains(newGroup)
	tracker := statistic.NewTCPTracker(conn, statistic.DefaultManager, &constant.Metadata{}, nil, 0, 0, true)
	t.Cleanup(func() { _ = tracker.Close(); _ = r.Close() })

	_, startVersion := routeStamp()

	// Delayed callback arrives from the OLD unloaded group instance (oldGroup)
	outboundgroup.OnGroupNowChanged(oldGroup, "AutoGroup", "NodeA", "NodeB")

	// Verify: The new connection must NOT be closed!
	if count := countConnections(); count != 1 {
		t.Errorf("expected new connection to be preserved, got count = %d", count)
	}
	if statistic.DefaultManager.Get(tracker.ID()) == nil {
		t.Errorf("new connection was closed by stale old group callback!")
	}

	// Verify: Route version must NOT increment
	_, endVersion := routeStamp()
	if endVersion != startVersion {
		t.Errorf("route version incremented by stale callback: start=%d, end=%d", startVersion, endVersion)
	}
}

type cancelableMockProxy struct {
	constant.Proxy
	name       string
	probeCount *atomic.Int32
	started    chan struct{}
}

func (m *cancelableMockProxy) Name() string { return m.name }
func (m *cancelableMockProxy) URLTest(ctx context.Context, url string, expectedStatus utils.IntRanges[uint16]) (uint16, error) {
	m.probeCount.Add(1)
	select {
	case <-m.started:
	default:
		close(m.started)
	}
	<-ctx.Done()
	return 0, ctx.Err()
}

func TestProviderProbeCancelsMidwayWithoutStartingRemaining(t *testing.T) {
	var probeCount atomic.Int32
	started := make(chan struct{})

	const totalProxies = 10
	proxies := make([]constant.Proxy, totalProxies)
	for i := 0; i < totalProxies; i++ {
		proxies[i] = &cancelableMockProxy{
			name:       fmt.Sprintf("mock-prov-node-%d", i),
			probeCount: &probeCount,
			started:    started,
		}
	}

	ctx, cancel := context.WithCancel(context.Background())

	done := make(chan struct{})
	go func() {
		defer close(done)
		_ = runBoundedProbes(ctx, len(proxies), 1, func(probeCtx context.Context, idx int) bool {
			if probeCtx.Err() != nil {
				return false
			}
			_, _ = proxies[idx].URLTest(probeCtx, "http://test.com", nil)
			return true
		})
	}()

	// Wait until the first proxy has started
	<-started

	// Cancel context midway
	cancel()

	// Wait for pool to exit
	select {
	case <-done:
	case <-time.After(1 * time.Second):
		t.Fatal("runBoundedProbes did not return promptly after context cancellation")
	}

	// Verify: Only 1 proxy was ever started; remaining 9 were never probed
	if count := probeCount.Load(); count != 1 {
		t.Fatalf("expected exactly 1 probe to start before cancel, got %d", count)
	}
}


type mockStatusProxy struct {
	constant.Proxy
	name           string
	receivedStatus utils.IntRanges[uint16]
	called         atomic.Int32
}

func (m *mockStatusProxy) Name() string { return m.name }
func (m *mockStatusProxy) URLTest(ctx context.Context, url string, expectedStatus utils.IntRanges[uint16]) (uint16, error) {
	m.called.Add(1)
	m.receivedStatus = expectedStatus
	return 100, nil
}

type mockFallbackProvider struct {
	cp.ProxyProvider
	name           string
	proxies        []constant.Proxy
	url            string
	expectedStatus utils.IntRanges[uint16]
	timeout        time.Duration
}

func (m *mockFallbackProvider) Name() string                                            { return m.name }
func (m *mockFallbackProvider) Proxies() []constant.Proxy                               { return m.proxies }
func (m *mockFallbackProvider) Touch()                                                  {}
func (m *mockFallbackProvider) HealthCheckURL() string                                  { return m.url }
func (m *mockFallbackProvider) HealthCheckExpectedStatus() utils.IntRanges[uint16]     { return m.expectedStatus }
func (m *mockFallbackProvider) HealthCheckTimeout() time.Duration                      { return m.timeout }

func TestProviderFallbackExpectedStatusPropagated(t *testing.T) {
	exp, err := utils.NewUnsignedRanges[uint16]("204")
	if err != nil {
		t.Fatal(err)
	}

	proxy := &mockStatusProxy{name: "node-with-expected-status"}
	p := &mockFallbackProvider{
		name:           "prov-status",
		proxies:        []constant.Proxy{proxy},
		url:            "http://example.com/check",
		expectedStatus: exp,
		timeout:        1 * time.Second,
	}

	providerMap := map[string]cp.ProxyProvider{
		"prov-status": p,
	}

	probeProvidersFallback(context.Background(), providerMap)

	if proxy.called.Load() != 1 {
		t.Fatalf("expected proxy to be called once, got %d", proxy.called.Load())
	}
	if proxy.receivedStatus == nil || proxy.receivedStatus.String() != "204" {
		t.Fatalf("expected proxy to receive expectedStatus 204, got %v", proxy.receivedStatus)
	}
}

func TestProviderFallbackPerNodeTimeoutEnforced(t *testing.T) {
	slowProxy := &cancelableMockProxy{
		name:       "slow-node",
		probeCount: new(atomic.Int32),
		started:    make(chan struct{}),
	}

	p := &mockFallbackProvider{
		name:    "prov-timeout",
		proxies: []constant.Proxy{slowProxy},
		url:     "http://example.com/check",
		timeout: 50 * time.Millisecond,
	}

	providerMap := map[string]cp.ProxyProvider{
		"prov-timeout": p,
	}

	start := time.Now()
	probeProvidersFallback(context.Background(), providerMap)
	timeoutElapsed := time.Since(start)

	if timeoutElapsed > 300*time.Millisecond {
		t.Fatalf("probeProvidersFallback did not enforce 50ms provider timeout, took %v", timeoutElapsed)
	}
}

func TestProviderFallbackDifferentInstancesWithSameNameAreBothProbed(t *testing.T) {
	// Two different proxy instances with the same name "HK-01"
	p1 := &mockStatusProxy{name: "HK-01"}
	p2 := &mockStatusProxy{name: "HK-01"}

	prov1 := &mockFallbackProvider{
		name:    "prov-1",
		proxies: []constant.Proxy{p1},
		url:     "http://check1.com",
		timeout: 1 * time.Second,
	}
	prov2 := &mockFallbackProvider{
		name:    "prov-2",
		proxies: []constant.Proxy{p2},
		url:     "http://check2.com",
		timeout: 1 * time.Second,
	}

	providerMap := map[string]cp.ProxyProvider{
		"prov-1": prov1,
		"prov-2": prov2,
	}

	probeProvidersFallback(context.Background(), providerMap)

	if p1.called.Load() != 1 {
		t.Fatalf("expected p1 to be probed once, got %d", p1.called.Load())
	}
	if p2.called.Load() != 1 {
		t.Fatalf("expected p2 to be probed once, got %d", p2.called.Load())
	}
}

type mockSelectorAdapter struct {
	constant.ProxyAdapter
	name string
	now  string
}

func (m *mockSelectorAdapter) Name() string                     { return m.name }
func (m *mockSelectorAdapter) Type() constant.AdapterType       { return constant.Selector }
func (m *mockSelectorAdapter) Now() string                      { return m.now }
func (m *mockSelectorAdapter) Touch()                           {}
func (m *mockSelectorAdapter) Hidden() bool                     { return false }
func (m *mockSelectorAdapter) Icon() string                     { return "" }
func (m *mockSelectorAdapter) Providers() []cp.ProxyProvider    { return nil }
func (m *mockSelectorAdapter) Proxies() []constant.Proxy        { return nil }
func (m *mockSelectorAdapter) URLTest(ctx context.Context, url string, expectedStatus utils.IntRanges[uint16]) (map[string]uint16, error) {
	return nil, nil
}

type mockAutoGroupAdapter struct {
	constant.ProxyAdapter
	name                   string
	groupType              constant.AdapterType
	proxies                []constant.Proxy
	consecutiveResets      atomic.Int32
	testTimeout            time.Duration
	healthCheckContextFunc func(context.Context) (map[string]uint16, error)
}

func (m *mockAutoGroupAdapter) Name() string                     { return m.name }
func (m *mockAutoGroupAdapter) Type() constant.AdapterType       { return m.groupType }
func (m *mockAutoGroupAdapter) Now() string                      { return "" }
func (m *mockAutoGroupAdapter) Touch()                           {}
func (m *mockAutoGroupAdapter) Hidden() bool                     { return false }
func (m *mockAutoGroupAdapter) Icon() string                     { return "" }
func (m *mockAutoGroupAdapter) Providers() []cp.ProxyProvider    { return nil }
func (m *mockAutoGroupAdapter) Proxies() []constant.Proxy        { return m.proxies }
func (m *mockAutoGroupAdapter) GetProxies(bool) []constant.Proxy { return m.proxies }
func (m *mockAutoGroupAdapter) TestTimeout() time.Duration       { return m.testTimeout }
func (m *mockAutoGroupAdapter) ResetConsecutiveFailures()         { m.consecutiveResets.Add(1) }
func (m *mockAutoGroupAdapter) HealthCheckContext(ctx context.Context) (map[string]uint16, error) {
	if m.healthCheckContextFunc != nil {
		return m.healthCheckContextFunc(ctx)
	}
	return nil, nil
}
func (m *mockAutoGroupAdapter) URLTest(ctx context.Context, url string, expectedStatus utils.IntRanges[uint16]) (map[string]uint16, error) {
	return nil, nil
}

func TestClassifyAutoGroupsActiveVsKeywords(t *testing.T) {
	activeAuto := &mockAutoGroupAdapter{name: "RegularAuto", groupType: constant.URLTest}
	inactiveKeywordAuto := &mockAutoGroupAdapter{name: "Inactive-Auto-Test", groupType: constant.URLTest}
	selector := &mockSelectorAdapter{name: "PROXY", now: "RegularAuto"}

	tunnel.UpdateProxies(map[string]constant.Proxy{
		"RegularAuto":        adapter.NewProxy(activeAuto),
		"Inactive-Auto-Test": adapter.NewProxy(inactiveKeywordAuto),
		"PROXY":              adapter.NewProxy(selector),
	}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })

	primary, secondary := classifyAutoGroups()

	// Only activeAuto should be in primary; inactiveKeywordAuto should be secondary
	if len(primary) != 1 || primary[0].Name() != "RegularAuto" {
		t.Fatalf("expected primary to contain only RegularAuto, got %v", primary)
	}
	if len(secondary) != 1 || secondary[0].Name() != "Inactive-Auto-Test" {
		t.Fatalf("expected secondary to contain Inactive-Auto-Test, got %v", secondary)
	}

	// Test fallback: no selector active, both become primary, keyword acts as tiebreaker
	tunnel.UpdateProxies(map[string]constant.Proxy{
		"PlainGroup":         adapter.NewProxy(&mockAutoGroupAdapter{name: "PlainGroup", groupType: constant.URLTest}),
		"AutoGroup":          adapter.NewProxy(&mockAutoGroupAdapter{name: "AutoGroup", groupType: constant.URLTest}),
	}, nil)

	primaryFallback, secondaryFallback := classifyAutoGroups()
	if len(secondaryFallback) != 0 {
		t.Fatalf("expected 0 secondary on fallback, got %d", len(secondaryFallback))
	}
	if len(primaryFallback) != 2 {
		t.Fatalf("expected 2 primary on fallback, got %d", len(primaryFallback))
	}
	if primaryFallback[0].Name() != "AutoGroup" {
		t.Fatalf("expected AutoGroup (keyword) to sort before PlainGroup, got %s", primaryFallback[0].Name())
	}
}

func TestCalculateGroupProbeBudget(t *testing.T) {
	// 1 proxy with default timeout (5s): 1 batch * 5s + 500ms = 5500ms
	g1 := adapter.NewProxy(&mockAutoGroupAdapter{
		name:    "g1",
		proxies: make([]constant.Proxy, 1),
	})
	if b := calculateGroupProbeBudget(g1); b != 5500*time.Millisecond {
		t.Fatalf("expected 5500ms for 1 proxy with default timeout, got %v", b)
	}

	// 20 proxies with default timeout: 2 batches * 5s + 500ms = 10500ms
	g20 := adapter.NewProxy(&mockAutoGroupAdapter{
		name:    "g20",
		proxies: make([]constant.Proxy, 20),
	})
	if b := calculateGroupProbeBudget(g20); b != 10500*time.Millisecond {
		t.Fatalf("expected 10500ms for 20 proxies with default timeout, got %v", b)
	}

	// 100 proxies with default timeout: bounded at 30s
	g100 := adapter.NewProxy(&mockAutoGroupAdapter{
		name:    "g100",
		proxies: make([]constant.Proxy, 100),
	})
	if b := calculateGroupProbeBudget(g100); b != 30*time.Second {
		t.Fatalf("expected 30s cap for 100 proxies, got %v", b)
	}

	// Group with custom timeout: e.g. 2s timeout, 1 batch = 2500ms
	gCustom := adapter.NewProxy(&mockAutoGroupAdapter{
		name:        "gCustom",
		proxies:     make([]constant.Proxy, 1),
		testTimeout: 2 * time.Second,
	})
	if b := calculateGroupProbeBudget(gCustom); b != 2500*time.Millisecond {
		t.Fatalf("expected 2500ms for custom 2s timeout, got %v", b)
	}

	// Group with competing candidates: 5 proxies + 10 competing proxies = 15 proxies (2 batches * 5s + 500ms = 10500ms)
	gComp := adapter.NewProxy(&mockAutoGroupAdapter{
		name:    "gComp",
		proxies: make([]constant.Proxy, 5),
	})
	if b := calculateGroupProbeBudget(gComp, 10); b != 10500*time.Millisecond {
		t.Fatalf("expected 10500ms for 5 proxies with 10 competing candidates, got %v", b)
	}
}

func TestResetAllGroupsConsecutiveFailures(t *testing.T) {
	g := &mockAutoGroupAdapter{name: "auto-group", groupType: constant.URLTest}
	tunnel.UpdateProxies(map[string]constant.Proxy{
		"auto-group": adapter.NewProxy(g),
	}, nil)
	t.Cleanup(func() { tunnel.UpdateProxies(nil, nil) })

	resetAllGroupsConsecutiveFailures()
	if count := g.consecutiveResets.Load(); count != 1 {
		t.Fatalf("expected 1 reset call, got %d", count)
	}
}

func TestOnGroupNowChangedPreservesHealthyNodeConnections(t *testing.T) {
	if outboundgroup.OnGroupNowChanged == nil {
		t.Fatal("outboundgroup.OnGroupNowChanged is nil, want initialized in core/connection.go")
	}

	statistic.DefaultManager.ResetStatistic()

	nodeAProxy := &mockProxyWithAlive{name: "NodeA", alive: true}
	nodeBProxy := &mockProxyWithAlive{name: "NodeB", alive: true}
	baseGroup := outbound.NewRejectWithOption(outbound.RejectOption{Name: "AutoGroup"})
	group := &mockGroupWithProxies{
		ProxyAdapter: baseGroup,
		name:         "AutoGroup",
		proxies:      []constant.Proxy{nodeAProxy, nodeBProxy},
	}

	nodeA := outbound.NewRejectWithOption(outbound.RejectOption{Name: "NodeA"})
	nodeB := outbound.NewRejectWithOption(outbound.RejectOption{Name: "NodeB"})

	l1, r1 := net.Pipe()
	conn1 := outbound.NewConn(l1, nodeA)
	conn1.AppendToChains(nodeA)
	conn1.AppendToChains(group)
	tracker1 := statistic.NewTCPTracker(conn1, statistic.DefaultManager, &constant.Metadata{}, nil, 0, 0, true)

	l2, r2 := net.Pipe()
	conn2 := outbound.NewConn(l2, nodeB)
	conn2.AppendToChains(nodeB)
	conn2.AppendToChains(group)
	tracker2 := statistic.NewTCPTracker(conn2, statistic.DefaultManager, &constant.Metadata{}, nil, 0, 0, true)

	tunnel.UpdateProxies(map[string]constant.Proxy{
		"AutoGroup": adapter.NewProxy(group),
	}, nil)

	t.Cleanup(func() {
		_ = tracker1.Close()
		_ = tracker2.Close()
		_ = r1.Close()
		_ = r2.Close()
		tunnel.UpdateProxies(nil, nil)
		statistic.DefaultManager.ResetStatistic()
	})

	if count := countConnections(); count != 2 {
		t.Fatalf("expected 2 active connections before reselection, got %d", count)
	}

	// 1. Healthy latency reselection during network probing: NodeA is healthy -> MUST PRESERVE CONNECTIONS!
	done := markNetworkProbing("AutoGroup")
	outboundgroup.OnGroupNowChanged(group, "AutoGroup", "NodeA", "NodeB")
	done()

	if count := countConnections(); count != 2 {
		t.Fatalf("expected 2 active connections after healthy reselection, got %d", count)
	}
	if statistic.DefaultManager.Get(tracker1.ID()) == nil {
		t.Errorf("expected healthy NodeA connection to be preserved, but was closed")
	}

	// 2. NodeA failure (alive: false) -> MUST CLOSE STALE CONNECTION!
	nodeAProxy.alive = false
	done = markNetworkProbing("AutoGroup")
	outboundgroup.OnGroupNowChanged(group, "AutoGroup", "NodeA", "NodeB")
	done()

	if count := countConnections(); count != 1 {
		t.Fatalf("expected 1 active connection after dead node reselection, got %d", count)
	}
	if statistic.DefaultManager.Get(tracker1.ID()) != nil {
		t.Errorf("expected dead NodeA connection to be closed, but still in manager")
	}
	if statistic.DefaultManager.Get(tracker2.ID()) == nil {
		t.Errorf("expected NodeB connection to remain active, but was closed")
	}
}

func TestProbeGroupsConcurrentlyCompletionContract(t *testing.T) {
	// 1. Single group complete success
	gSuccess := adapter.NewProxy(&mockAutoGroupAdapter{
		name:      "gSuccess",
		groupType: constant.URLTest,
		proxies:   make([]constant.Proxy, 2),
		healthCheckContextFunc: func(ctx context.Context) (map[string]uint16, error) {
			return map[string]uint16{"n1": 50, "n2": 80}, nil
		},
	})
	if ok := probeGroupsConcurrently(context.Background(), []*adapter.Proxy{gSuccess}); !ok {
		t.Fatalf("expected true for fully complete group check, got false")
	}

	// 2. Single group partial success (deadline exceeded, but some nodes succeeded)
	// Must return false to signal that the group check was incomplete and needs retry!
	gPartial := adapter.NewProxy(&mockAutoGroupAdapter{
		name:      "gPartial",
		groupType: constant.URLTest,
		proxies:   make([]constant.Proxy, 5),
		healthCheckContextFunc: func(ctx context.Context) (map[string]uint16, error) {
			return map[string]uint16{"n1": 50}, context.DeadlineExceeded
		},
	})
	if ok := probeGroupsConcurrently(context.Background(), []*adapter.Proxy{gPartial}); ok {
		t.Fatalf("expected false for deadline-truncated partial group check, got true")
	}

	// 3. Multiple groups: Group 1 complete, Group 2 partial
	// Must return false because Group 2 is not complete!
	if ok := probeGroupsConcurrently(context.Background(), []*adapter.Proxy{gSuccess, gPartial}); ok {
		t.Fatalf("expected false when any group in batch is incomplete, got true")
	}

	// 4. Multiple groups: both complete -> returns true
	gSuccess2 := adapter.NewProxy(&mockAutoGroupAdapter{
		name:      "gSuccess2",
		groupType: constant.Fallback,
		proxies:   make([]constant.Proxy, 3),
		healthCheckContextFunc: func(ctx context.Context) (map[string]uint16, error) {
			return map[string]uint16{"n3": 60}, nil
		},
	})
	if ok := probeGroupsConcurrently(context.Background(), []*adapter.Proxy{gSuccess, gSuccess2}); !ok {
		t.Fatalf("expected true when all groups complete, got false")
	}

	// 5. Single group complete failure (all failed) -> returns false
	gFail := adapter.NewProxy(&mockAutoGroupAdapter{
		name:      "gFail",
		groupType: constant.URLTest,
		proxies:   make([]constant.Proxy, 2),
		healthCheckContextFunc: func(ctx context.Context) (map[string]uint16, error) {
			return nil, errors.New("all nodes failed")
		},
	})
	if ok := probeGroupsConcurrently(context.Background(), []*adapter.Proxy{gFail}); ok {
		t.Fatalf("expected false for all-failed group, got true")
	}

	// 6. Active cancellation -> returns false
	ctxCanceled, cancel := context.WithCancel(context.Background())
	cancel()
	if ok := probeGroupsConcurrently(ctxCanceled, []*adapter.Proxy{gSuccess}); ok {
		t.Fatalf("expected false on canceled context, got true")
	}
}
