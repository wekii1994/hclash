package core

import (
	"io"
	"net"
	"testing"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outbound"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/constant"
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
