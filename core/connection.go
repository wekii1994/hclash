package core

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/metacubex/mihomo/adapter"
	"github.com/metacubex/mihomo/adapter/outboundgroup"
	"github.com/metacubex/mihomo/common/utils"
	"github.com/metacubex/mihomo/component/resolver"
	C "github.com/metacubex/mihomo/constant"
	cp "github.com/metacubex/mihomo/constant/provider"
	"github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"github.com/metacubex/mihomo/tunnel/statistic"
)

func handleCloseGroupStaleConnections(groupName, oldProxyName string, switchTime time.Time) {
	if groupName == "" || oldProxyName == "" {
		return
	}
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		info := c.Info()
		if info == nil {
			return true
		}
		if !switchTime.IsZero() && info.Start.After(switchTime) {
			return true
		}
		hasGroup := false
		hasOldProxy := false
		for _, node := range info.Chain {
			if node == groupName {
				hasGroup = true
			}
			if node == oldProxyName {
				hasOldProxy = true
			}
		}
		if hasGroup && hasOldProxy {
			_ = c.Close()
		}
		return true
	})
}

var (
	networkProbingGroups   = make(map[string]int)
	networkProbingGroupsMu sync.Mutex
)

func markNetworkProbing(name string) func() {
	networkProbingGroupsMu.Lock()
	networkProbingGroups[name]++
	networkProbingGroupsMu.Unlock()
	return func() {
		networkProbingGroupsMu.Lock()
		networkProbingGroups[name]--
		if networkProbingGroups[name] <= 0 {
			delete(networkProbingGroups, name)
		}
		networkProbingGroupsMu.Unlock()
	}
}

func isNetworkProbing(name string) bool {
	networkProbingGroupsMu.Lock()
	defer networkProbingGroupsMu.Unlock()
	return networkProbingGroups[name] > 0
}

func getGroupTestURL(group C.ProxyAdapter) (testURL string) {
	if group == nil {
		return ""
	}
	defer func() {
		if r := recover(); r != nil {
			testURL = ""
		}
	}()
	if m, ok := group.(interface{ MarshalJSON() ([]byte, error) }); ok {
		data, err := m.MarshalJSON()
		if err == nil {
			var parsed struct {
				TestURL string `json:"testUrl"`
			}
			if json.Unmarshal(data, &parsed) == nil && parsed.TestURL != "" {
				return parsed.TestURL
			}
		}
	}
	return ""
}

func isGroupProxyAlive(group C.ProxyAdapter, proxyName string) bool {
	if group == nil || proxyName == "" {
		return false
	}
	testURL := getGroupTestURL(group)
	if g, ok := group.(interface{ GetProxies(bool) []C.Proxy }); ok {
		for _, p := range g.GetProxies(false) {
			if p.Name() == proxyName {
				if testURL != "" {
					return p.AliveForTestUrl(testURL)
				}
				return p.AliveForTestUrl("")
			}
		}
	}
	return false
}

func init() {
	outboundgroup.OnGroupNowChanged = func(group C.ProxyAdapter, groupName, before, after string) {
		configMu.Lock()
		defer configMu.Unlock()
		selectMu.Lock()
		defer selectMu.Unlock()

		activeProxy := tunnel.AllProxies()[groupName]
		if activeProxy == nil {
			return
		}
		if group != nil {
			if p, ok := activeProxy.(*adapter.Proxy); ok {
				if p.ProxyAdapter != group {
					log.Debugln("[Failover] Suppressed stale failover from unloaded group instance %s", groupName)
					return
				}
			} else if activeProxy != group {
				log.Debugln("[Failover] Suppressed stale failover from unloaded group instance %s", groupName)
				return
			}
		}

		if isNetworkProbing(groupName) && isGroupProxyAlive(group, before) {
			log.Debugln("[Failover] Suppressed failover count for healthy node latency reselection on group %s: [%s] -> [%s]", groupName, before, after)
		} else {
			log.Infoln("[Failover] Proxy group %s auto switched from [%s] to [%s] via passive failure detection", groupName, before, after)
			recordFailover(groupName, before, after)
		}
		handleCloseGroupStaleConnections(groupName, before, time.Now())
		refreshRouteLocked(routeMoved)
	}
}

const (
	networkSettleDelay      = 300 * time.Millisecond
	networkRetryBackoff     = 1200 * time.Millisecond
	primaryProbeConcurrency = 3
)

var (
	resetNetworkMu     sync.Mutex
	resetNetworkCancel context.CancelFunc
	networkProbeRound  atomic.Uint64
)

func handleGetTraffic(params TrafficParams) Traffic {
	up, down := statistic.DefaultManager.NowTraffic(params.OnlyProxy)
	return Traffic{Up: up, Down: down}
}

func handleGetTotalTraffic(params TrafficParams) Traffic {
	up, down := statistic.DefaultManager.TotalTraffic(params.OnlyProxy)
	return Traffic{Up: up, Down: down}
}

func handleResetTraffic() {
	statistic.DefaultManager.ResetStatistic()
}

func handleGetConnections() *statistic.Snapshot {
	return statistic.DefaultManager.Snapshot()
}

func handleGetConnectionCount() int {
	count := 0
	statistic.DefaultManager.Range(func(statistic.Tracker) bool {
		count++
		return true
	})
	return count
}

func handleCloseConnections() {
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		_ = c.Close()
		return true
	})
}

func handleResetConnections() {
	resolver.ResetConnection()
}

func handleClearDnsCache() {
	configMu.Lock()
	defer configMu.Unlock()
	dns.ClearAll()
}

// handleNetworkChanged is how the desktop host reports a new network, which
// Android's NetworkObserver reports through handleResetNetwork.
func handleNetworkChanged() {
	handleClearDnsCache()
}

type touchable interface {
	Touch()
}

func touchGroup(group *adapter.Proxy) {
	if group == nil {
		return
	}
	if t, ok := group.ProxyAdapter.(touchable); ok {
		t.Touch()
		return
	}
	_ = group.Unwrap(nil, true)
}

func isAutoGroup(p *adapter.Proxy) bool {
	if p == nil {
		return false
	}
	switch p.Type() {
	case C.URLTest, C.Fallback:
		return true
	default:
		return false
	}
}

func hasPrimaryAutoKeyword(name string) bool {
	lower := strings.ToLower(name)
	for _, kw := range []string{"自动", "auto", "url-test", "best", "优选", "极速", "主力"} {
		if strings.Contains(lower, kw) {
			return true
		}
	}
	return false
}

// classifyAutoGroups 结合当前活跃路由拓扑（Selector -> Now 引用链）与名称特征，划分主次自动策略组。
func classifyAutoGroups() (primary []*adapter.Proxy, secondary []*adapter.Proxy) {
	allProxies := tunnel.Proxies()
	activeNames := make(map[string]struct{})

	// 沿着所有 Selector 的当前选中项向下展开，标记正在承载流量的策略组
	for _, raw := range allProxies {
		p, ok := raw.(*adapter.Proxy)
		if !ok || p.Type() != C.Selector {
			continue
		}
		curr := p
		for depth := 0; depth < 6 && curr != nil; depth++ {
			pg, ok := curr.ProxyAdapter.(outboundgroup.ProxyGroup)
			if !ok {
				break
			}
			nowName := pg.Now()
			if nowName == "" {
				break
			}
			if _, visited := activeNames[nowName]; visited {
				break
			}
			activeNames[nowName] = struct{}{}
			nextRaw, exists := allProxies[nowName]
			if !exists {
				break
			}
			nextProxy, ok := nextRaw.(*adapter.Proxy)
			if !ok {
				break
			}
			curr = nextProxy
		}
	}

	for _, raw := range allProxies {
		p, ok := raw.(*adapter.Proxy)
		if !ok || !isAutoGroup(p) {
			continue
		}
		_, isActive := activeNames[p.Name()]
		if isActive {
			primary = append(primary, p)
		} else {
			secondary = append(secondary, p)
		}
	}

	if len(primary) == 0 && len(secondary) > 0 {
		primary = secondary
		secondary = nil
	}

	sort.SliceStable(primary, func(i, j int) bool {
		_, aActive := activeNames[primary[i].Name()]
		_, bActive := activeNames[primary[j].Name()]
		if aActive != bActive {
			return aActive
		}
		aHasKw := hasPrimaryAutoKeyword(primary[i].Name())
		bHasKw := hasPrimaryAutoKeyword(primary[j].Name())
		if aHasKw != bHasKw {
			return aHasKw
		}
		return primary[i].Name() < primary[j].Name()
	})
	return primary, secondary
}

func snapshotGroupSelections(groups []*adapter.Proxy) map[string]string {
	res := make(map[string]string, len(groups))
	for _, g := range groups {
		if pg, ok := g.ProxyAdapter.(outboundgroup.ProxyGroup); ok {
			res[g.Name()] = pg.Now()
		}
	}
	return res
}

func hasSelectionChanged(before map[string]string, groups []*adapter.Proxy) bool {
	for _, g := range groups {
		if pg, ok := g.ProxyAdapter.(outboundgroup.ProxyGroup); ok {
			if before[g.Name()] != pg.Now() {
				return true
			}
		}
	}
	return false
}

type contextHealthCheckedGroup interface {
	HealthCheckContext(context.Context) (map[string]uint16, error)
}

type failureResetter interface {
	ResetConsecutiveFailures()
}

// Require the companion Mihomo patch at compile time, not only at runtime.
var _ contextHealthCheckedGroup = (*outboundgroup.URLTest)(nil)
var _ contextHealthCheckedGroup = (*outboundgroup.Fallback)(nil)
var _ failureResetter = (*outboundgroup.URLTest)(nil)
var _ failureResetter = (*outboundgroup.Fallback)(nil)

func resetAllGroupsConsecutiveFailures() {
	for _, raw := range tunnel.Proxies() {
		if p, ok := raw.(*adapter.Proxy); ok {
			if r, ok := p.ProxyAdapter.(failureResetter); ok {
				r.ResetConsecutiveFailures()
			}
		}
	}
}

func calculateGroupProbeBudget(proxy *adapter.Proxy) time.Duration {
	if pg, ok := proxy.ProxyAdapter.(outboundgroup.ProxyGroup); ok {
		return outboundgroup.RoundBudget(len(pg.Proxies()), 0)
	}
	return outboundgroup.RoundBudget(1, 0)
}

func probeGroupsConcurrently(ctx context.Context, groups []*adapter.Proxy) bool {
	return runBoundedProbes(ctx, len(groups), primaryProbeConcurrency,
		func(probeCtx context.Context, index int) bool {
			g := groups[index]
			checker, ok := g.ProxyAdapter.(contextHealthCheckedGroup)
			if !ok {
				return false
			}
			done := markNetworkProbing(g.Name())
			defer done()
			budget := calculateGroupProbeBudget(g)
			testCtx, cancel := context.WithTimeout(probeCtx, budget)
			defer cancel()
			results, err := checker.HealthCheckContext(testCtx)
			return err == nil && len(results) > 0
		})
}

func waitOrCancel(ctx context.Context, d time.Duration) bool {
	timer := time.NewTimer(d)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

func cancelResetNetwork() {
	resetNetworkMu.Lock()
	if resetNetworkCancel != nil {
		resetNetworkCancel()
		resetNetworkCancel = nil
	}
	resetNetworkMu.Unlock()
}

func probeProvidersFallback(ctx context.Context, providerMap map[string]cp.ProxyProvider) {
	type providerProbeItem struct {
		proxy          C.Proxy
		url            string
		expectedStatus utils.IntRanges[uint16]
		timeout        time.Duration
	}
	var items []providerProbeItem
	seen := make(map[string]bool)
	for _, p := range providerMap {
		if p == nil {
			continue
		}
		p.Touch()
		url := p.HealthCheckURL()
		if url == "" {
			url = defaultTestURL
		}
		expectedStatus := p.HealthCheckExpectedStatus()
		timeout := p.HealthCheckTimeout()
		if timeout <= 0 {
			timeout = 5 * time.Second
		}

		expectedStr := ""
		if expectedStatus != nil {
			expectedStr = expectedStatus.String()
		}

		for _, proxy := range p.Proxies() {
			if proxy == nil {
				continue
			}
			// Deduplicate by instance pointer identity + check conditions
			dedupKey := fmt.Sprintf("%p|%s|%s", proxy, url, expectedStr)
			if !seen[dedupKey] {
				seen[dedupKey] = true
				items = append(items, providerProbeItem{
					proxy:          proxy,
					url:            url,
					expectedStatus: expectedStatus,
					timeout:        timeout,
				})
			}
		}
	}
	_ = runBoundedProbes(ctx, len(items), primaryProbeConcurrency, func(probeCtx context.Context, idx int) bool {
		if probeCtx.Err() != nil {
			return false
		}
		item := items[idx]
		nodeCtx, nodeCancel := context.WithTimeout(probeCtx, item.timeout)
		defer nodeCancel()
		_, _ = item.proxy.URLTest(nodeCtx, item.url, item.expectedStatus)
		return true
	})
}

func handleResetNetwork() {
	handleCloseConnections()
	handleClearDnsCache()
	resetAllGroupsConsecutiveFailures()

	resetNetworkMu.Lock()
	if resetNetworkCancel != nil {
		resetNetworkCancel()
	}
	ctx, cancel := context.WithCancel(context.Background())
	resetNetworkCancel = cancel
	resetNetworkMu.Unlock()

	startEpoch, _ := routeStamp()
	probeRound := networkProbeRound.Add(1)

	resetCtx := outboundgroup.WithProbeRound(ctx, probeRound)
	go func(resetCtx context.Context) {
		defer cancel()
		defer outboundgroup.CleanupProbeRound(probeRound)

		if !waitOrCancel(resetCtx, networkSettleDelay) {
			return
		}
		if endEpoch, _ := routeStamp(); endEpoch != startEpoch {
			return
		}

		primaryGroups, secondaryGroups := classifyAutoGroups()
		_ = secondaryGroups
		beforeSelections := snapshotGroupSelections(primaryGroups)

		if len(primaryGroups) > 0 {
			ok := probeGroupsConcurrently(resetCtx, primaryGroups)
			if !ok && waitOrCancel(resetCtx, networkRetryBackoff) {
				handleClearDnsCache()
				if endEpoch, _ := routeStamp(); endEpoch == startEpoch {
					retryRound := networkProbeRound.Add(1)
					retryCtx := outboundgroup.WithProbeRound(resetCtx, retryRound)
					defer outboundgroup.CleanupProbeRound(retryRound)
					_ = probeGroupsConcurrently(retryCtx, primaryGroups)
				}
			}
		} else {
			probeProvidersFallback(resetCtx, tunnel.ProvidersSnapshot())
		}

		if resetCtx.Err() != nil {
			return
		}
		if endEpoch, _ := routeStamp(); endEpoch != startEpoch {
			return
		}

		for _, g := range primaryGroups {
			if pg, ok := g.ProxyAdapter.(outboundgroup.ProxyGroup); ok {
				before := beforeSelections[g.Name()]
				after := pg.Now()
				if before != "" && after != "" && before != after {
					handleCloseGroupStaleConnections(g.Name(), before, time.Now())
				}
			}
		}
		changeRoute(routeMoved)
	}(resetCtx)
}

// A connection that is already gone is closed as far as the host is concerned.
func handleCloseConnection(params IDParams) error {
	if c := statistic.DefaultManager.Get(params.ID); c != nil {
		_ = c.Close()
	}
	return nil
}
